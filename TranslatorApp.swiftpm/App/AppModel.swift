import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Central coordinator: audio session/engine, per-channel gating and
/// resampling, one translation session per speaker, push-to-talk return
/// channel, playback ducking, and transcript/cost bookkeeping.
///
/// Threading: @Published state is only touched on the main thread. The audio
/// tap hands buffers to `audioQueue` for gating/resampling/sending.
final class AppModel: ObservableObject {

    enum Mode: Equatable {
        case idle
        case bench          // meters only, no translation sessions
        case conversation
        case pushToTalk
    }

    // MARK: - Published UI state (main thread only)

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var lanes: [SpeakerLane] = []
    @Published private(set) var meters: [Float] = []
    @Published private(set) var gateOpen: [Bool] = []
    @Published private(set) var sessionStates: [Int: LaneSessionState] = [:]
    @Published private(set) var route: AudioSessionController.RouteSnapshot?
    @Published private(set) var estimatedCost: Double = 0
    @Published var errorBanner: String?
    @Published private(set) var speakerOverrideActive = false
    @Published private(set) var pttLevel: Float = 0

    let transcript: TranscriptStore

    /// Signal-tab analysis. Deliberately its own ObservableObject (not
    /// forwarded through objectWillChange) so its 5-10 Hz snapshot churn
    /// only re-renders views that observe it directly.
    let signalAnalyzer = SignalAnalyzer()

    // MARK: - Pipeline components

    let audioSession = AudioSessionController()
    private let engineGraph = EngineGraph()
    private let gate = ChannelGate()
    private let costMeter = CostMeter()
    private let audioQueue = DispatchQueue(label: "translator.audio.pipeline", qos: .userInitiated)

    /// Apple Translation framework broker (staged pipeline's on-device
    /// translation provider). The broker is pure queue plumbing — only the
    /// bridge views that serve it are iOS 18-gated.
    let translationBroker = AppleTranslationBroker()

    /// laneID -> client. DJI lanes are 0..<channelCount; the user's
    /// push-to-talk lane is SpeakerLane.userLaneID.
    /// `clients`, `resamplers`, and `gate` internals are confined to
    /// audioQueue (mutations from the main thread hop via audioQueue.sync)
    /// because the tap pipeline reads them concurrently.
    private var clients: [Int: any TranslationLaneSession] = [:]
    private var resamplers: [Int: StreamResampler] = [:]
    private var reconnectAttempts: [Int: Int] = [:]
    private var sessionOpenedAt: [Int: Date] = [:]

    // audioQueue-confined lazy-session state. Sessions open on first
    // detected speech per channel (a powered-off TX is pure silence and
    // never opens one) and are closed again after idle timeout.
    private var pipelineActive = false
    private var sessionAPIKey: String?
    /// Pipeline mode + staged provider configuration snapshotted at Start:
    /// lanes opened mid-conversation must match what the Start-time key
    /// check validated (a Settings flip applies on the next Start).
    /// audioQueue-confined like sessionAPIKey.
    private var sessionPipelineMode: AppSettings.PipelineMode = .realtime
    private var sessionStagedConfig: AppSettings.StagedConfig?
    private var lastVoiceAt: [Int: Date] = [:]
    /// Last logged voiced state per channel (audioQueue-confined) so
    /// speech start/end transitions land in the diagnostics log.
    private var voicedState: [Int: Bool] = [:]

    // Engine watchdog bookkeeping (main thread). The engine auto-stops on
    // configuration changes and interruptions; the watchdog brings it back.
    private var interruptedSince: Date?
    private var lastWatchdogRestart = Date.distantPast
    private var lastEngineDownWarn = Date.distantPast

    /// Playback lanes on the engine: 0..3 = translated English per speaker,
    /// 4 = the user's translated Chinese.
    private let zhPlaybackLane = 4
    private var pendingPlaybackBuffers: [Int: Int] = [:]
    private var zhSpeakerPlaybackOutstanding = 0

    private var uiTimer: Timer?
    private var stopping = false
    private var cancellables: Set<AnyCancellable> = []

    // Read on the tap thread, written on main — lock-protected.
    private let pttFlagLock = NSLock()
    private var _pttEngaged = false
    private var pttEngaged: Bool {
        get { pttFlagLock.lock(); defer { pttFlagLock.unlock() }; return _pttEngaged }
        set { pttFlagLock.lock(); _pttEngaged = newValue; pttFlagLock.unlock() }
    }

    init() {
        transcript = TranscriptStore()
        engineGraph.outputGain = AppSettings.outputGain
        // Nested ObservableObject: forward its changes so views observing
        // AppModel re-render on transcript updates.
        transcript.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        observeNotifications()
    }

    // MARK: - Conversation lifecycle

    func startConversation() {
        guard mode == .idle else { return }
        let pipelineMode = AppSettings.pipelineMode
        let stagedConfig = pipelineMode == .staged ? AppSettings.stagedConfig() : nil
        let apiKey = KeychainStore.loadAPIKey()
        // The staged pipeline only needs a key for its OpenAI stages; an
        // all-on-device configuration starts without one.
        let needsKey = pipelineMode == .realtime || (stagedConfig?.needsOpenAIKey ?? false)
        if needsKey, (apiKey ?? "").isEmpty {
            errorBanner = "Add your OpenAI API key in Settings first."
            return
        }
        // Pre-flight the one staged configuration that can't translate at
        // all: Apple Intelligence unavailable with no key to fall back to.
        if #available(iOS 26.0, *),
           stagedConfig?.translationProvider == .appleIntelligence,
           (apiKey ?? "").isEmpty,
           let problem = FoundationModelsTranslator.availabilityProblem {
            errorBanner = "Apple Intelligence is unavailable (\(problem)). Add an OpenAI key for fallback or pick another translator."
            return
        }
        errorBanner = nil
        stopping = false
        // The estimate next to the lane dots reads as "this conversation's
        // cost" — start it from zero.
        costMeter.reset()
        refreshCost()

        do {
            try audioSession.configureForConversation()
        } catch {
            errorBanner = "Audio session setup failed: \(error.localizedDescription)"
            return
        }
        refreshRoute()

        do {
            try engineGraph.start(playerCount: zhPlaybackLane + 1)
        } catch {
            errorBanner = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }

        let channelCount = min(4, engineGraph.inputChannelCount)
        lanes = (0..<channelCount).map { SpeakerLane.djiLane(channel: $0, name: AppSettings.speakerName($0)) }
        meters = Array(repeating: 0, count: channelCount)
        gateOpen = Array(repeating: false, count: channelCount)

        audioQueue.sync {
            applyGateTuningLocked()
            gate.reset()
            pipelineActive = true
            sessionAPIKey = apiKey
            sessionPipelineMode = pipelineMode
            sessionStagedConfig = stagedConfig
            lastVoiceAt.removeAll()
            voicedState.removeAll()
        }
        buildResamplers(channelCount: channelCount)
        // Sessions are opened lazily on first speech per channel, not here —
        // a disconnected/powered-off TX never opens a billed session.
        sessionStates = Dictionary(uniqueKeysWithValues: (0..<channelCount).map { ($0, LaneSessionState.idle) })

        signalAnalyzer.startSession()
        installInputHandler()
        startUITimer()
        mode = .conversation
        UIApplication.shared.isIdleTimerDisabled = true
        Log.info("Conversation started: \(channelCount) channel(s); sessions open on first speech")
    }

    func stopConversation() {
        guard mode != .idle else { return }
        stopping = true
        mode = .idle
        pttEngaged = false
        uiTimer?.invalidate()
        uiTimer = nil
        engineGraph.onInputChannels = nil
        engineGraph.stop()
        audioQueue.sync {
            pipelineActive = false
            sessionAPIKey = nil
            sessionStagedConfig = nil
            lastVoiceAt.removeAll()
            for (_, client) in clients { client.close() }
            clients.removeAll()
            resamplers.removeAll()
        }
        sessionStates.removeAll()
        reconnectAttempts.removeAll()
        sessionOpenedAt.removeAll()
        resetPlaybackState()
        UIApplication.shared.isIdleTimerDisabled = false
        refreshCost()
        Log.info("Conversation stopped")
    }

    private func buildResamplers(channelCount: Int) {
        let rate = engineGraph.inputSampleRate
        audioQueue.sync {
            resamplers.removeAll()
            for channel in 0..<channelCount {
                resamplers[channel] = StreamResampler(inputSampleRate: rate)
            }
        }
    }

    /// Player nodes are torn down on every engine rebuild and their pending
    /// completion handlers may never fire — reset the counters that ducking
    /// and the speaker override key off, or they wedge.
    private func resetPlaybackState() {
        pendingPlaybackBuffers.removeAll()
        zhSpeakerPlaybackOutstanding = 0
        if speakerOverrideActive {
            audioSession.overrideToSpeaker(false)
            speakerOverrideActive = false
        }
    }

    // MARK: - Input pipeline

    private func installInputHandler() {
        engineGraph.onInputChannels = { [weak self] channelPointers, frames, sampleRate in
            guard let self else { return }
            // Copy on the tap thread — the pointers die when the callback
            // returns — then process off-thread.
            if self.pttEngaged {
                guard let first = channelPointers.first,
                      let buffer = EngineGraph.monoBuffer(from: first, frames: frames, sampleRate: sampleRate) else { return }
                let rms = ChannelGate.rms(samples: first, count: frames)
                self.audioQueue.async { self.processPTTBuffer(buffer, rms: rms) }
            } else {
                let laneCount = min(4, channelPointers.count)
                var buffers: [AVAudioPCMBuffer] = []
                for index in 0..<laneCount {
                    guard let buffer = EngineGraph.monoBuffer(from: channelPointers[index], frames: frames, sampleRate: sampleRate) else { return }
                    buffers.append(buffer)
                }
                self.audioQueue.async { self.processConversationBuffers(buffers, frames: frames, sampleRate: sampleRate) }
            }
        }
    }

    /// Runs on audioQueue.
    private func processConversationBuffers(_ buffers: [AVAudioPCMBuffer], frames: Int, sampleRate: Double) {
        // The gate needs the samples (not just levels) to cross-correlate
        // channels for bleed rejection; the buffers stay alive for the call.
        var channels: [UnsafePointer<Float>] = []
        channels.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.floatChannelData else { return }
            channels.append(UnsafePointer(data[0]))
        }
        // UserDefaults is thread-safe; reading per buffer means a Settings
        // toggle mutes/unmutes a mic mid-conversation.
        let enabledMask = (0..<channels.count).map { AppSettings.speakerEnabled($0) }
        let decisions = gate.evaluate(channels: channels, frames: frames, sampleRate: sampleRate, channelEnabled: enabledMask)
        // Fan out to the Signal tab. When the tab is hidden this is a flag
        // check and return; otherwise the buffers are retained (no copy)
        // onto the analyzer's lower-priority queue.
        signalAnalyzer.ingest(buffers: buffers, frames: frames, sampleRate: sampleRate, telemetry: gate.lastTelemetry)
        for (channel, decision) in decisions.enumerated() {
            // Log utterance-level transitions (the hangover smooths word
            // gaps) so missing translations can be correlated with whether
            // speech was even detected and whether the gate passed it.
            if decision.voiced != (voicedState[channel] ?? false) {
                voicedState[channel] = decision.voiced
                if decision.voiced {
                    Log.info("ch\(channel) speech started (rms \(String(format: "%.4f", decision.rms)), gate \(decision.pass ? "pass" : (decision.bleed ? "SUPPRESSED as bleed" : "suppressed")))")
                } else {
                    Log.info("ch\(channel) speech ended")
                }
            }
            // Keyed on pass AND voiced: bleed from another speaker must
            // neither open a session for this lane nor keep it alive
            // (pass is false for bleed), and with the gate disabled — where
            // pass is unconditionally true, silence included — only detected
            // speech may open sessions or defeat the idle-close timer.
            // With the gate enabled the conjunction is identical to pass
            // alone (pass implies genuine-or-hangover, which implies voiced).
            let speech = decision.pass && decision.voiced
            if speech { lastVoiceAt[channel] = Date() }
            guard let resampler = resamplers[channel] else { continue }
            guard let client = clients[channel] ?? lazyOpenSession(channel: channel, speech: speech) else { continue }
            let outgoing: AVAudioPCMBuffer?
            if decision.pass {
                outgoing = buffers[channel]
            } else {
                // Replace suppressed audio with silence to keep the session's
                // audio timeline continuous.
                outgoing = EngineGraph.silentBuffer(frames: frames, sampleRate: sampleRate)
            }
            if let outgoing, let data = resampler.convert(outgoing) {
                client.sendAudio(data)
            }
        }
        pushMeters(decisions)
    }

    /// Runs on audioQueue. Opens a channel's translation session the first
    /// time genuine (non-bleed) speech is detected on it; the client queues
    /// audio while the socket connects, so the triggering words are
    /// translated too.
    private func lazyOpenSession(channel: Int, speech: Bool) -> (any TranslationLaneSession)? {
        guard speech, pipelineActive else { return nil }
        Log.info("Speech on channel \(channel) — opening translation session")
        let client = makeClient(lane: channel, outputLanguage: AppSettings.outputLanguage,
                                apiKey: sessionAPIKey, pipelineMode: sessionPipelineMode,
                                stagedConfig: sessionStagedConfig)
        clients[channel] = client
        client.connect()
        return client
    }

    /// Runs on audioQueue.
    private func processPTTBuffer(_ buffer: AVAudioPCMBuffer, rms: Float) {
        let level = min(1, rms * 12)
        DispatchQueue.main.async { self.pttLevel = level }
        lastVoiceAt[SpeakerLane.userLaneID] = Date()
        guard let resampler = resamplers[SpeakerLane.userLaneID],
              let client = clients[SpeakerLane.userLaneID],
              let data = resampler.convert(buffer) else { return }
        client.sendAudio(data)
    }

    private var lastMeterPush = Date.distantPast

    private func pushMeters(_ decisions: [ChannelGate.Decision]) {
        let now = Date()
        guard now.timeIntervalSince(lastMeterPush) > 0.1 else { return }
        lastMeterPush = now
        let levels = decisions.map { min(1, $0.rms * 12) }
        let open = decisions.map(\.pass)
        DispatchQueue.main.async {
            if self.meters.count == levels.count {
                self.meters = levels
                self.gateOpen = open
            }
        }
    }

    // MARK: - Sessions

    /// Create and wire a client for the active pipeline mode without
    /// registering or connecting it. Safe to call from any thread
    /// (settings/keychain are thread-safe).
    private func makeClient(lane: Int, outputLanguage: String, apiKey: String?,
                            pipelineMode: AppSettings.PipelineMode,
                            stagedConfig: AppSettings.StagedConfig?) -> any TranslationLaneSession {
        let label = lane == SpeakerLane.userLaneID ? "me→\(outputLanguage)" : "ch\(lane)→\(outputLanguage)"
        let client: any TranslationLaneSession
        if #available(iOS 26.0, *), pipelineMode == .staged, let stagedConfig {
            client = makeStagedClient(lane: lane, label: label, outputLanguage: outputLanguage,
                                      apiKey: apiKey, config: stagedConfig)
        } else {
            var config = SessionConfig(outputLanguage: outputLanguage)
            config.model = AppSettings.modelName
            config.noiseReduction = AppSettings.noiseReduction
            client = RealtimeTranslationClient(
                label: label,
                config: config,
                apiKey: apiKey ?? "",
                endpointTemplate: AppSettings.endpointTemplate
            )
        }
        wireClient(client, lane: lane)
        return client
    }

    /// Assemble the staged pipeline (on-device STT → translator → TTS) from
    /// the configuration snapshotted at Start.
    @available(iOS 26.0, *)
    private func makeStagedClient(lane: Int, label: String, outputLanguage: String,
                                  apiKey: String?, config: AppSettings.StagedConfig) -> any TranslationLaneSession {
        let translator: any UtteranceTranslator
        switch config.translationProvider {
        case .openAIText:
            translator = OpenAITextTranslator(apiKey: apiKey ?? "", model: config.textModelName)
        case .appleTranslation:
            translator = AppleTranslationTranslator(broker: translationBroker)
        case .appleIntelligence:
            if let onDevice = FoundationModelsTranslator() {
                translator = onDevice
            } else if let apiKey, !apiKey.isEmpty {
                Log.warn("[\(label)] Apple Intelligence unavailable — falling back to OpenAI text translation")
                translator = OpenAITextTranslator(apiKey: apiKey, model: config.textModelName)
            } else {
                // Start pre-flights this; reachable only if availability
                // changed mid-conversation. Segments degrade to source-only.
                translator = UnavailableTranslator(reason: "Apple Intelligence is unavailable on this device and no OpenAI key is saved")
            }
        }
        // Dense 0..4 index for the auto-distinct voice rotation, stable
        // regardless of which TXs are attached (4 = the PTT user lane).
        // Explicit picks (any lane's) are excluded from the rotation so an
        // auto lane can't land on a voice someone was given by name.
        let laneIndex = lane == SpeakerLane.userLaneID ? 4 : lane
        let synthesizer: (any SpeechSynthesisStage)?
        switch config.ttsProvider {
        case .onDevice:
            synthesizer = OnDeviceSynthesizer(
                explicitVoiceIdentifier: config.onDeviceVoice(forLane: lane),
                laneIndex: laneIndex,
                excludedVoiceIdentifiers: Set(config.onDeviceVoices.values.filter { !$0.isEmpty })
            )
        case .openAI:
            synthesizer = OpenAISynthesizer(
                apiKey: apiKey ?? "",
                model: config.openAITTSModel,
                explicitVoice: config.openAIVoice(forLane: lane),
                laneIndex: laneIndex,
                excludedVoices: Set(config.openAIVoices.values.filter { !$0.isEmpty })
            )
        case .none:
            synthesizer = nil
        }
        let sourceLocale = lane == SpeakerLane.userLaneID
            ? config.userLanguage
            : config.sourceLanguage
        return StagedTranslationClient(
            label: label,
            sourceLocaleIdentifier: sourceLocale,
            targetLanguage: outputLanguage,
            translator: translator,
            synthesizer: synthesizer
        )
    }

    /// Main-thread path (push-to-talk lane): register + connect.
    private func openClient(lane: Int, outputLanguage: String, apiKey: String?) {
        let (pipelineMode, stagedConfig) = audioQueue.sync { (sessionPipelineMode, sessionStagedConfig) }
        let client = makeClient(lane: lane, outputLanguage: outputLanguage,
                                apiKey: apiKey, pipelineMode: pipelineMode,
                                stagedConfig: stagedConfig)
        audioQueue.sync { clients[lane] = client }
        client.connect()
    }

    private func wireClient(_ client: any TranslationLaneSession, lane: Int) {
        let isUserLane = lane == SpeakerLane.userLaneID

        client.onStateChange = { [weak self, weak client] state in
            DispatchQueue.main.async {
                guard let self, let client else { return }
                // Ignore events from clients no longer registered for this
                // lane (e.g. after an idle-close) so they can't clobber the
                // lane's displayed state or trigger reconnects.
                guard self.audioQueue.sync(execute: { self.clients[lane] === client }) else { return }
                switch state {
                case .open:
                    self.sessionOpenedAt[lane] = Date()
                case .closed:
                    // Only a session that survived a while proves the config
                    // works; resetting the attempt counter on every open let
                    // an open-then-instant-reject loop retry forever.
                    if let openedAt = self.sessionOpenedAt.removeValue(forKey: lane),
                       Date().timeIntervalSince(openedAt) >= 5 {
                        self.reconnectAttempts[lane] = 0
                    }
                    self.scheduleReconnectIfNeeded(lane: lane)
                default:
                    break
                }
                self.sessionStates[lane] = state
            }
        }
        client.onSourceTranscriptDelta = { [weak self] delta in
            DispatchQueue.main.async { self?.transcript.appendSourceDelta(lane: lane, text: delta) }
        }
        client.onTranslatedTranscriptDelta = { [weak self] delta in
            DispatchQueue.main.async { self?.transcript.appendTranslationDelta(lane: lane, text: delta) }
        }
        // Deliberately NOT identity-guarded like the callbacks above: an
        // idle-closed client is deregistered before its close() drain
        // finishes, and the audio billed during that drain must still count.
        // CostMeter is thread-safe, so no main hop either.
        client.onBilledSeconds = { [weak self] seconds in
            self?.costMeter.addBilledSeconds(seconds)
        }
        client.onTranslatedAudio = { [weak self] audio in
            guard let self else { return }
            DispatchQueue.main.async {
                if isUserLane {
                    self.handleChineseAudio(audio)
                } else {
                    self.playEnglishAudio(audio, lane: lane)
                }
            }
        }

        // Staged-pipeline callbacks. The realtime client stores these but
        // never fires them; the staged client uses them instead of the
        // append-only delta callbacks above.
        client.onSegmentSource = { [weak self] segmentID, text, isFinal in
            DispatchQueue.main.async {
                self?.transcript.upsertSegmentSource(lane: lane, segmentID: segmentID, text: text, isFinal: isFinal)
            }
        }
        client.onSegmentTranslation = { [weak self] segmentID, delta in
            DispatchQueue.main.async {
                self?.transcript.appendSegmentTranslation(lane: lane, segmentID: segmentID, text: delta)
            }
        }
        client.onSegmentAudio = { [weak self] segmentID, audio in
            guard let self else { return }
            DispatchQueue.main.async {
                if isUserLane {
                    self.handleUserLaneAudio(audio) {
                        self.transcript.appendSegmentAudio(lane: lane, segmentID: segmentID, audio: audio)
                    }
                } else {
                    self.playEnglishAudio(audio, lane: lane)
                }
            }
        }
        client.onSegmentCompleted = { [weak self] segmentID in
            DispatchQueue.main.async {
                self?.transcript.finalizeSegment(segmentID)
            }
        }
        // Like onBilledSeconds: thread-safe meter, no identity guard, no
        // main hop — cost reported during a close drain must still count.
        client.onCostDollars = { [weak self] dollars in
            self?.costMeter.addDollars(dollars)
        }
    }

    private func scheduleReconnectIfNeeded(lane: Int) {
        DispatchQueue.main.async {
            guard !self.stopping, self.mode != .idle else { return }
            guard self.audioQueue.sync(execute: { self.clients[lane] != nil }) else { return }
            let attempts = (self.reconnectAttempts[lane] ?? 0) + 1
            self.reconnectAttempts[lane] = attempts
            guard attempts <= 5 else {
                self.errorBanner = "Session for \(self.laneName(lane)) keeps failing — check the API key and event log."
                return
            }
            let delay = min(10, pow(2, Double(attempts)))
            Log.warn("Reconnecting \(self.laneName(lane)) in \(Int(delay))s (attempt \(attempts))")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !self.stopping, self.mode != .idle else { return }
                self.audioQueue.sync(execute: { self.clients[lane] })?.connect()
            }
        }
    }

    func laneName(_ laneID: Int) -> String {
        if laneID == SpeakerLane.userLaneID { return AppSettings.userName }
        return lanes.first(where: { $0.id == laneID })?.name ?? "Speaker \(laneID + 1)"
    }

    func lane(for laneID: Int) -> SpeakerLane {
        if laneID == SpeakerLane.userLaneID { return SpeakerLane.userLane(name: AppSettings.userName) }
        return lanes.first(where: { $0.id == laneID }) ?? SpeakerLane.djiLane(channel: max(0, laneID))
    }

    /// Live update from the Settings volume slider (main thread).
    func setOutputGain(_ gain: Float) {
        engineGraph.outputGain = gain
    }

    // MARK: - English playback with overlap ducking (main thread)

    private func playEnglishAudio(_ audio: Data, lane: Int) {
        if !engineGraph.engine.isRunning, Date().timeIntervalSince(lastEngineDownWarn) > 5 {
            lastEngineDownWarn = Date()
            Log.warn("Translated audio arriving for lane \(lane) but the audio engine is not running — playback stalled (watchdog will restart it)")
        }
        let othersActive = pendingPlaybackBuffers.contains { $0.key != lane && $0.key != zhPlaybackLane && $0.value > 0 }
        engineGraph.setLaneVolume(othersActive ? 0.35 : 1.0, lane: lane)
        pendingPlaybackBuffers[lane, default: 0] += 1
        engineGraph.schedule(pcm16: audio, lane: lane) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingPlaybackBuffers[lane] = max(0, (self.pendingPlaybackBuffers[lane] ?? 1) - 1)
                if self.pendingPlaybackBuffers[lane] == 0 {
                    self.engineGraph.setLaneVolume(1.0, lane: lane)
                }
            }
        }
    }

    // MARK: - Push-to-talk (main thread)

    func pttPressed() {
        guard mode == .conversation else { return }
        let apiKey = KeychainStore.loadAPIKey()
        // Same rule as Start, against the Start-time snapshot: only the
        // OpenAI-backed stages need a key.
        let (pipelineMode, stagedConfig) = audioQueue.sync { (sessionPipelineMode, sessionStagedConfig) }
        let needsKey = pipelineMode == .realtime || (stagedConfig?.needsOpenAIKey ?? false)
        if needsKey, (apiKey ?? "").isEmpty { return }
        mode = .pushToTalk
        pttEngaged = true
        Log.info("PTT engaged — switching input to AirPods mic")

        engineGraph.stop()
        resetPlaybackState()
        do {
            try audioSession.configureForPushToTalk()
        } catch {
            Log.error("PTT session config failed: \(error.localizedDescription)")
        }
        // The route change settles asynchronously; give it a beat before the
        // engine rebuilds against the new input format.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.pttEngaged, self.mode == .pushToTalk else { return }
            do {
                try self.engineGraph.start(playerCount: self.zhPlaybackLane + 1)
            } catch {
                Log.error("PTT engine start failed: \(error.localizedDescription)")
            }
            let rate = self.engineGraph.inputSampleRate
            self.audioQueue.sync {
                self.resamplers[SpeakerLane.userLaneID] = StreamResampler(inputSampleRate: rate)
            }
            if self.audioQueue.sync(execute: { self.clients[SpeakerLane.userLaneID] }) == nil {
                self.openClient(lane: SpeakerLane.userLaneID, outputLanguage: AppSettings.pttOutputLanguage, apiKey: apiKey)
            }
            self.refreshRoute()
        }
    }

    func pttReleased() {
        guard mode == .pushToTalk else { return }
        pttEngaged = false
        Log.info("PTT released — restoring USB input")

        engineGraph.stop()
        resetPlaybackState()
        do {
            try audioSession.configureForConversation()
        } catch {
            Log.error("Restoring conversation session failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.pttEngaged, self.mode == .pushToTalk else { return }
            do {
                try self.engineGraph.start(playerCount: self.zhPlaybackLane + 1)
                self.buildResamplers(channelCount: self.lanes.count)
                self.audioQueue.sync { self.gate.reset() }
            } catch {
                Log.error("Engine restart failed: \(error.localizedDescription)")
            }
            self.refreshRoute()
            self.pttLevel = 0
            self.mode = .conversation
        }
    }

    // MARK: - Chinese (user lane) playback (main thread)

    private func handleChineseAudio(_ audio: Data) {
        handleUserLaneAudio(audio) {
            transcript.appendTranslatedAudio(lane: SpeakerLane.userLaneID, audio: audio)
        }
    }

    /// User-lane playback policy, shared by both pipelines: store the audio
    /// for replay (the caller picks the transcript keying) and auto-play it
    /// over the speaker if enabled.
    private func handleUserLaneAudio(_ audio: Data, attach: () -> Void) {
        attach()
        if AppSettings.autoPlayChinese {
            playChineseOverSpeaker(audio)
        }
    }

    /// Replay a finished utterance's Chinese audio over the iPad speaker.
    func playUtteranceAudio(_ utterance: TranscriptStore.Utterance) {
        // Player nodes only exist while the engine runs.
        guard mode != .idle, let audio = utterance.translatedAudio else { return }
        playChineseOverSpeaker(audio)
    }

    private func playChineseOverSpeaker(_ audio: Data) {
        if zhSpeakerPlaybackOutstanding == 0 {
            audioSession.overrideToSpeaker(true)
            speakerOverrideActive = true
        }
        zhSpeakerPlaybackOutstanding += 1
        engineGraph.schedule(pcm16: audio, lane: zhPlaybackLane) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.zhSpeakerPlaybackOutstanding = max(0, self.zhSpeakerPlaybackOutstanding - 1)
                if self.zhSpeakerPlaybackOutstanding == 0 {
                    self.audioSession.overrideToSpeaker(false)
                    self.speakerOverrideActive = false
                }
            }
        }
    }

    // MARK: - Gate tuning

    private var gateTuningApplyScheduled = false

    /// Apply the persisted gate tunables to the live gate. Coalesced on a
    /// 100 ms trailing edge: the tuning sliders fire onChange dozens of
    /// times per second during a drag, and the audio queue must not be
    /// flooded with redundant re-apply blocks. Main thread.
    func applyGateTuning() {
        guard !gateTuningApplyScheduled else { return }
        gateTuningApplyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.gateTuningApplyScheduled = false
            self.audioQueue.async { self.applyGateTuningLocked() }
        }
    }

    /// Must run on audioQueue (UserDefaults reads are thread-safe). Reads
    /// through GateSettingsSnapshot so the gate, the Signal tab display,
    /// and the export all share one roster of tunables.
    private func applyGateTuningLocked() {
        let tuning = GateSettingsSnapshot.current()
        gate.enabled = tuning.enabled
        gate.neuralVADEnabled = tuning.neuralVAD
        gate.minimumVoiceThreshold = tuning.minimumVoiceThreshold
        gate.snrFactor = tuning.snrFactor
        gate.bleedCorrelation = tuning.bleedCorrelation
        gate.takeoverMargin = tuning.takeoverMargin
        gate.hangover = tuning.hangover
        gate.vadOnProbability = tuning.vadOnProbability
        gate.vadOffProbability = tuning.vadOffProbability
        gate.sustainedVoiceTimeout = tuning.sustainedVoiceTimeout
    }

    // MARK: - Diagnostics support

    func refreshRoute() {
        DispatchQueue.main.async {
            self.route = self.audioSession.snapshot()
        }
    }

    /// One-shot audio session activation for the bench-test screen, without
    /// starting any translation sessions.
    func startBenchTest() {
        guard mode == .idle else { return }
        do {
            try audioSession.configureForConversation()
            try engineGraph.start(playerCount: 1)
        } catch {
            errorBanner = "Bench test failed: \(error.localizedDescription)"
            return
        }
        let channelCount = min(4, engineGraph.inputChannelCount)
        lanes = (0..<channelCount).map { SpeakerLane.djiLane(channel: $0, name: AppSettings.speakerName($0)) }
        meters = Array(repeating: 0, count: channelCount)
        gateOpen = Array(repeating: false, count: channelCount)
        // Run the gate with the real settings (it used to be disabled here)
        // so the Signal tab shows genuine gate behavior without any API
        // cost. Bench meters/gate dots now reflect gating too.
        audioQueue.sync {
            applyGateTuningLocked()
            gate.reset()
        }
        signalAnalyzer.startSession()
        installInputHandler()
        // Bench mode has no clients; processConversationBuffers still runs
        // and drives the meters, sends go nowhere. The UI timer runs so the
        // engine watchdog can recover from config-change auto-stops — bench
        // is the mode used to provoke exactly those (replugs, BT churn).
        startUITimer()
        refreshRoute()
        mode = .bench
        Log.info("Bench test running: \(channelCount) channel(s) at \(Int(engineGraph.inputSampleRate)) Hz")
    }

    // MARK: - Timers & notifications

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshCost()
            self.transcript.finalizeStale(timeout: 2.5)
            self.closeIdleSessions()
            self.watchdogEngineCheck()
        }
    }

    /// AVAudioEngine auto-stops on configuration changes (Bluetooth codec
    /// renegotiation, USB glitches) and interruptions, and before this
    /// watchdog nothing ever restarted it — the classic "playback never
    /// continues after a pause" failure. Restart it whenever it's found dead
    /// outside an active interruption.
    private func watchdogEngineCheck() {
        guard mode == .conversation || mode == .bench, !pttEngaged, !engineGraph.engine.isRunning else { return }
        // During an interruption the session can't be reactivated; wait for
        // the .ended notification, but only up to 60 s — it famously doesn't
        // always arrive.
        if let since = interruptedSince, Date().timeIntervalSince(since) < 60 { return }
        guard Date().timeIntervalSince(lastWatchdogRestart) >= 5 else { return }
        lastWatchdogRestart = Date()
        Log.warn("Watchdog: audio engine stopped (config change or interruption) — restarting")
        restartEngineForCurrentRoute()
    }

    /// Close sessions whose channel has been silent past the idle timeout —
    /// they reopen automatically on the next detected speech. Stops billing
    /// for quiet channels and for the PTT lane between uses. Sessions on
    /// mics disabled in Settings close immediately, timeout or not.
    private func closeIdleSessions() {
        guard mode != .idle else { return }
        let timeout = AppSettings.idleCloseSeconds
        let now = Date()
        var closedLanes: [Int] = []
        var disabledLanes: Set<Int> = []
        audioQueue.sync {
            for (lane, client) in clients {
                if lane == SpeakerLane.userLaneID && pttEngaged { continue }
                if lane >= 0 && !AppSettings.speakerEnabled(lane) {
                    disabledLanes.insert(lane)
                } else {
                    guard timeout > 0, let last = lastVoiceAt[lane],
                          now.timeIntervalSince(last) > timeout else { continue }
                }
                clients[lane] = nil
                client.close()
                closedLanes.append(lane)
            }
        }
        for lane in closedLanes {
            sessionStates[lane] = .idle
            sessionOpenedAt[lane] = nil
            reconnectAttempts[lane] = 0
            if disabledLanes.contains(lane) {
                Log.info("Closed session for \(laneName(lane)) — mic disabled in Settings")
            } else {
                Log.info("Closed idle session for \(laneName(lane)) (silent \(Int(timeout))s) — reopens on speech")
            }
        }
    }

    private func refreshCost() {
        estimatedCost = costMeter.estimatedDollars
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSpeakerNames()
        }
    }

    /// Lanes are built at Start, so without this a speaker renamed in
    /// Settings kept the old name in the conversation until a restart.
    /// Fires on every defaults write; the equality checks make writes to
    /// unrelated keys (sliders, toggles) no-ops.
    private var lastUserName = AppSettings.userName

    private func refreshSpeakerNames() {
        if AppSettings.userName != lastUserName {
            lastUserName = AppSettings.userName
            // The user lane is derived from AppSettings at render time
            // (`lane(for:)`), so a re-render is all it needs.
            objectWillChange.send()
        }
        guard !lanes.isEmpty else { return }
        let updated = lanes.map { SpeakerLane.djiLane(channel: $0.id, name: AppSettings.speakerName($0.id)) }
        if updated.map(\.name) != lanes.map(\.name) {
            lanes = updated
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshRoute()
        guard mode == .conversation || mode == .bench, !pttEngaged else { return }
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            Log.warn("Route change (\(reason == .oldDeviceUnavailable ? "device removed" : "device added")) — rebuilding engine")
            restartEngineForCurrentRoute()
        default:
            break
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interruptedSince = Date()
            Log.warn("Audio interruption began")
        case .ended:
            interruptedSince = nil
            guard mode != .idle else { return }
            Log.info("Audio interruption ended — restarting engine")
            restartEngineForCurrentRoute()
        @unknown default:
            break
        }
    }

    private func restartEngineForCurrentRoute() {
        guard mode == .conversation || mode == .bench else { return }
        engineGraph.stop()
        resetPlaybackState()
        do {
            try audioSession.configureForConversation()
            // Mirror what each mode's start built: bench runs one throwaway
            // player and no resamplers (nothing is sent anywhere).
            try engineGraph.start(playerCount: mode == .bench ? 1 : zhPlaybackLane + 1)
            if mode == .conversation {
                buildResamplers(channelCount: lanes.count)
            }
            audioQueue.sync { gate.reset() }
            refreshRoute()
        } catch {
            errorBanner = "Audio restart failed: \(error.localizedDescription)"
        }
    }
}
