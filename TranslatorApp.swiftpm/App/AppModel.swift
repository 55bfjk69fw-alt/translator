import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// 10 Hz per-channel level/gate state for the status dots and bench meters.
/// Deliberately its own ObservableObject (the SignalAnalyzer pattern): meter
/// churn re-renders only the views that draw meters, not everything that
/// observes AppModel — at 10 Hz for hours with the screen locked awake, that
/// difference is real CPU and battery. Main thread only.
final class ChannelMeters: ObservableObject {
    @Published private(set) var levels: [Float] = []
    @Published private(set) var gateOpen: [Bool] = []

    func reset(channelCount: Int) {
        levels = Array(repeating: 0, count: channelCount)
        gateOpen = Array(repeating: false, count: channelCount)
    }

    /// Drops pushes whose shape doesn't match the current session (a late
    /// hop from a torn-down pipeline), like the old AppModel guard did.
    func update(levels: [Float], gateOpen: [Bool]) {
        guard levels.count == self.levels.count else { return }
        self.levels = levels
        self.gateOpen = gateOpen
    }
}

/// Central coordinator: audio session/engine, per-channel gating and
/// resampling, one translation session per speaker, the reply prompter,
/// and transcript/cost bookkeeping.
///
/// Threading: @Published state is only touched on the main thread. The audio
/// tap hands buffers to `audioQueue` for gating/resampling/sending.
final class AppModel: ObservableObject {

    enum Mode: Equatable {
        case idle
        case starting       // Start's async window: AirPods claim, route settling
        case bench          // meters only, no translation sessions
        case conversation
    }

    // MARK: - Published UI state (main thread only)

    @Published private(set) var mode: Mode = .idle {
        // Every transition re-derives the idle-timer flag, so abort/error
        // paths back to .idle can't leave the screen pinned awake (or a
        // session mode running with auto-lock enabled).
        didSet { applyIdleTimerPolicy() }
    }
    @Published private(set) var lanes: [SpeakerLane] = []
    @Published private(set) var sessionStates: [Int: RealtimeTranslationClient.State] = [:]
    @Published private(set) var route: AudioSessionController.RouteSnapshot?
    @Published private(set) var estimatedCost: Double = 0
    @Published var errorBanner: String?

    /// One row of the Diagnostics "Translation pipeline" panel: everything
    /// between the gate and the transcript for one lane, sampled at 1 Hz by
    /// the UI timer. This is the tool for "the gate is open but nothing is
    /// showing up" — it localizes the break to gate/session/server stream.
    struct LanePipelineStatus: Identifiable {
        let id: Int            // lane ID (DJI channel)
        var name: String
        /// Gate currently passing this channel (mirror of the status dot).
        var gateOpen: Bool
        var secondsSinceSpeech: TimeInterval?
        /// nil = no session right now (they open lazily on first speech).
        var session: RealtimeTranslationClient.Snapshot?
    }

    @Published private(set) var pipelineStatuses: [LanePipelineStatus] = []

    let transcript: TranscriptStore

    /// 10 Hz level/gate dots. Its own ObservableObject so meter churn only
    /// re-renders the status bar and Diagnostics meter rows (see the class
    /// comment above).
    let channelMeters = ChannelMeters()

    /// Reply prompter (docs/REPLY-FLOW.md). Its own ObservableObject so the
    /// assist bar re-renders on suggestion churn without re-rendering the
    /// transcript, mirroring the SignalAnalyzer pattern.
    let assist = AssistEngine()

    /// Signal-tab analysis. Deliberately its own ObservableObject (not
    /// forwarded through objectWillChange) so its 5-10 Hz snapshot churn
    /// only re-renders views that observe it directly.
    let signalAnalyzer = SignalAnalyzer()

    /// Metrics-tab collector (cost/latency/throughput/prompter usage). Its
    /// own ObservableObject for the same reason as SignalAnalyzer: its 1 Hz
    /// snapshot churn only re-renders the Metrics tab.
    let metrics = MetricsStore()

    // MARK: - Pipeline components

    let audioSession = AudioSessionController()
    private let engineGraph = EngineGraph()
    private let gate = ChannelGate()
    private let costMeter = CostMeter()
    private let audioQueue = DispatchQueue(label: "translator.audio.pipeline", qos: .userInitiated)

    /// laneID -> client, one per DJI channel (0..<channelCount).
    /// `clients`, `resamplers`, and `gate` internals are confined to
    /// audioQueue (mutations from the main thread hop via audioQueue.sync)
    /// because the tap pipeline reads them concurrently.
    private var clients: [Int: RealtimeTranslationClient] = [:]
    private var resamplers: [Int: StreamResampler] = [:]
    private var reconnectAttempts: [Int: Int] = [:]
    private var sessionOpenedAt: [Int: Date] = [:]

    // audioQueue-confined lazy-session state. Sessions open on first
    // detected speech per channel (a powered-off TX is pure silence and
    // never opens one) and are closed again after idle timeout.
    private var pipelineActive = false
    private var sessionAPIKey: String?
    private var lastVoiceAt: [Int: Date] = [:]
    /// Last logged voiced state per channel (audioQueue-confined) so
    /// speech start/end transitions land in the diagnostics log.
    private var voicedState: [Int: Bool] = [:]
    /// Channels already warned about dropping gated speech for lack of a
    /// resampler (audioQueue-confined) — a silent-drop path that otherwise
    /// looks exactly like "gate open, nothing captured".
    private var warnedMissingResampler: Set<Int> = []

    // Gate-closed append pausing (audioQueue-confined). Sessions are no
    // longer fed silence for the whole lull between utterances: after the
    // gate's hangover closes, a short silence tail is appended (the server
    // segments phrases on trailing quiet), then the stream pauses entirely.
    // Server-verified safe: appended audio is treated as contiguous with
    // what came before (no timestamps on append), which is also why a
    // resume must splice in a quiet gap — otherwise the new phrase butts
    // against the previous one in session time.
    /// Buffers of trailing silence still owed to a lane's session.
    private var silenceTailRemaining: [Int: Int] = [:]
    /// Channels whose outbound stream is currently paused.
    private var appendPaused: Set<Int> = []
    /// Last 200 ms of real resampled audio per non-passing channel, sent on
    /// resume so the word onset the gate's attack clipped isn't lost.
    private var preRoll: [Int: Data] = [:]

    /// ~1.2 s of silence after the hangover closes — long enough to be the
    /// server's phrase-boundary cue, no longer billed past that.
    private static let silenceTailBufferCount = 6
    /// 300 ms splice inserted when a paused stream resumes.
    private static let resumeSpliceSilence = Data(count: 14_400) // 24 kHz PCM16

    // Engine watchdog bookkeeping (main thread). The engine auto-stops on
    // configuration changes and interruptions; the watchdog brings it back.
    private var interruptedSince: Date?
    private var lastWatchdogRestart = Date.distantPast
    private var lastEngineDownWarn = Date.distantPast

    /// Playback lanes on the engine: 0..3 = translated English per speaker.
    private let playbackLaneCount = 4
    private var pendingPlaybackBuffers: [Int: Int] = [:]

    private var uiTimer: Timer?
    /// Faster companion to uiTimer for transcript finalization only — at
    /// 1 Hz, bubble closes were quantized to the tick on top of the quiet
    /// timeout, adding up to a full second of visible linger.
    private var finalizeTimer: Timer?
    private var stopping = false

    // Start-window bookkeeping (main thread): the chime playing under the
    // AirPods-claim session, the poll waiting for the hop, and the one-shot
    // engine retry while the USB route settles.
    private var claimChime: AirPodsClaimChime?
    private var claimTimer: Timer?
    private var pendingEngineRetry: DispatchWorkItem?

    init() {
        AppSettings.migrateLegacyKeys()
        transcript = TranscriptStore()
        engineGraph.outputGain = AppSettings.outputGain
        // TranscriptStore's changes are deliberately NOT forwarded through
        // objectWillChange: views that show the transcript observe it
        // directly (it's injected as its own environment object), so a
        // streaming delta doesn't re-render everything observing AppModel.
        // Prompter wiring: the engine reads the transcript through these
        // closures and writes "I said this" turns back through them — it
        // never touches the audio pipeline (docs/REPLY-FLOW.md §3).
        // Open (still-streaming) utterances with any text are included and
        // marked in-progress — the sentence-boundary trigger fires while
        // someone is mid-utterance, and the fresh sentence must be in the
        // window for the early request to be worth anything.
        assist.transcriptWindow = { [weak self] in
            guard let self else { return [] }
            let now = Date()
            return self.transcript.utterances.suffix(60)
                .filter { $0.isFinal || !$0.sourceText.isEmpty || !$0.translatedText.isEmpty }
                .suffix(25)
                .map { utterance in
                    AssistEngine.TranscriptLine(
                        speaker: self.laneName(utterance.laneID),
                        source: utterance.sourceText,
                        translation: utterance.translatedText,
                        isUser: utterance.laneID == SpeakerLane.userLaneID,
                        isFinal: utterance.isFinal,
                        ageSeconds: max(0, Int(now.timeIntervalSince(utterance.lastActivity)))
                    )
                }
        }
        // Low-latency trigger: fire the moment a sentence lands in a
        // streaming delta instead of waiting for finalization + the next
        // 1 Hz tick. The engine's rate limit still bounds request volume.
        transcript.onSentenceBoundary = { [weak self] in
            guard let self, self.mode == .conversation else { return }
            self.assist.transcriptTick(contentEvents: self.transcript.finalizedTotal + self.transcript.sentenceEventTotal)
        }
        assist.onUserSaid = { [weak self] suggestion in
            // The literal meaning, not the intent gloss — the transcript
            // records what was actually said.
            self?.transcript.addUserUtterance(source: suggestion.hanzi, gloss: suggestion.meaning)
        }
        assist.recordMetric = { [weak self] sample in
            self?.metrics.recordAssist(sample)
        }
        observeNotifications()
    }

    // MARK: - Conversation lifecycle

    func startConversation() {
        guard mode == .idle else { return }
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            errorBanner = "Add your OpenAI API key in Settings first."
            return
        }
        errorBanner = nil
        stopping = false
        // The estimate next to the lane dots reads as "this conversation's
        // cost" — start it from zero.
        costMeter.reset()
        refreshCost()

        // Grab the AirPods from the phone before the conversation session
        // goes up (they only auto-switch for media playback, which
        // .playAndRecord never looks like — see configureForPlaybackClaim).
        // Only worth doing when the bare iPad speaker would be the output:
        // wired headphones, a BT speaker, or AirPods already routed here
        // all mean there's nothing to grab, and skipping spares those
        // setups the claim's chime-and-wait.
        if AppSettings.claimAirPodsAtStart && audioSession.outputIsBuiltInSpeaker {
            beginAirPodsClaim(apiKey: apiKey)
        } else {
            beginConversation(apiKey: apiKey)
        }
    }

    /// Briefly impersonate a media-playback app — .playback session plus an
    /// audible chime — so iPadOS's automatic switching pulls the AirPods to
    /// this device, the way YouTube does when it starts playing. Polls the
    /// route until the AirPods arrive (then lets the chime finish) or a
    /// timeout passes, then starts the conversation either way; a late hop
    /// is still caught by the route-change handler's engine rebuild.
    /// Best-effort: any failure just starts the conversation directly.
    private func beginAirPodsClaim(apiKey: String) {
        do {
            try audioSession.configureForPlaybackClaim()
        } catch {
            Log.warn("AirPods claim skipped — playback session failed: \(error.localizedDescription)")
            beginConversation(apiKey: apiKey)
            return
        }
        mode = .starting
        refreshRoute()
        let chime = AirPodsClaimChime()
        claimChime = chime
        chime.play()
        Log.info("Claiming AirPods: start chime playing under a media-playback session")
        let chimeDone = Date().addingTimeInterval(AirPodsClaimChime.duration)
        let deadline = Date().addingTimeInterval(3.5)
        claimTimer?.invalidate()
        // .common run-loop mode so a scroll gesture held through the claim
        // can't stall the poll (default-mode timers pause during tracking).
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, self.mode == .starting else {
                timer.invalidate()
                return
            }
            let now = Date()
            let claimed = self.audioSession.airPodsOutputActive
            guard (claimed && now >= chimeDone) || now >= deadline else { return }
            timer.invalidate()
            self.claimTimer = nil
            self.claimChime?.stop()
            self.claimChime = nil
            if claimed {
                Log.info("AirPods claim succeeded — AirPods are now this device's output")
            } else {
                Log.warn("AirPods claim timed out — output is \(self.audioSession.snapshot().outputs.joined(separator: ", ")). If they stayed on the phone, set Bluetooth → AirPods → Connect to This iPad → Automatically.")
            }
            // Drop the claim session before the conversation config: see
            // AudioSessionController.deactivate() — a fresh activation
            // settles the USB route synchronously, a live recategorization
            // doesn't.
            self.audioSession.deactivate()
            self.beginConversation(apiKey: apiKey)
        }
        claimTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPendingStart() {
        claimTimer?.invalidate()
        claimTimer = nil
        claimChime?.stop()
        claimChime = nil
        pendingEngineRetry?.cancel()
        pendingEngineRetry = nil
        // Whichever session shape the aborted Start left active, release it
        // (and let whatever the claim paused resume playing).
        audioSession.deactivate()
        mode = .idle
        Log.info("Start aborted during the claim/settle window")
    }

    /// The real conversation start — audio session, engine, lanes, timers.
    /// Runs straight from Start, or after the AirPods claim settles.
    private func beginConversation(apiKey: String) {
        mode = .starting
        do {
            try audioSession.configureForConversation()
        } catch {
            errorBanner = "Audio session setup failed: \(error.localizedDescription)"
            mode = .idle
            return
        }
        refreshRoute()
        startEngineAndFinish(apiKey: apiKey, isRetry: false)
    }

    /// Engine start plus everything downstream of it. After the claim's
    /// category flip the USB input can need a beat to re-attach (the same
    /// ~0.3 s settle the dual-input probe documents), and binding a
    /// transient route would fail the start — so a throw gets one retry
    /// after the route settles, and only the retry's failure surfaces.
    private func startEngineAndFinish(apiKey: String, isRetry: Bool) {
        do {
            try engineGraph.start(playerCount: playbackLaneCount)
        } catch {
            guard !isRetry else {
                errorBanner = "Audio engine failed to start: \(error.localizedDescription)"
                mode = .idle
                return
            }
            Log.warn("Engine start failed (\(error.localizedDescription)) — retrying once after the route settles")
            let retry = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .starting else { return }
                self.pendingEngineRetry = nil
                self.refreshRoute()
                self.startEngineAndFinish(apiKey: apiKey, isRetry: true)
            }
            pendingEngineRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: retry)
            return
        }

        let channelCount = min(4, engineGraph.inputChannelCount)
        lanes = (0..<channelCount).map { SpeakerLane.djiLane(channel: $0, name: AppSettings.speakerName($0)) }
        channelMeters.reset(channelCount: channelCount)

        audioQueue.sync {
            applyGateTuningLocked()
            gate.reset()
            pipelineActive = true
            sessionAPIKey = apiKey
            lastVoiceAt.removeAll()
            voicedState.removeAll()
        }
        buildResamplers(channelCount: channelCount)
        // Sessions are opened lazily on first speech per channel, not here —
        // a disconnected/powered-off TX never opens a billed session.
        sessionStates = Dictionary(uniqueKeysWithValues: (0..<channelCount).map { ($0, RealtimeTranslationClient.State.idle) })

        signalAnalyzer.startSession()
        // Reset only after every fallible setup step: a Start that dies on
        // the audio session/engine must not wipe the previous conversation's
        // still-inspectable metrics. Same "this conversation" framing as the
        // cost meter above.
        metrics.startSession()
        installInputHandler()
        startUITimer()
        mode = .conversation
        assist.conversationStarted(contentEvents: transcript.finalizedTotal + transcript.sentenceEventTotal)
        Log.info("Conversation started: \(channelCount) channel(s); sessions open on first speech")
    }

    func stopConversation() {
        // Stop during Start's async window (claim chime, engine retry):
        // nothing is fully running yet — just abort the pending start.
        if mode == .starting {
            cancelPendingStart()
            return
        }
        guard mode != .idle else { return }
        stopping = true
        mode = .idle
        assist.conversationEnded()
        uiTimer?.invalidate()
        uiTimer = nil
        finalizeTimer?.invalidate()
        finalizeTimer = nil
        engineGraph.onInputChannels = nil
        engineGraph.stop()
        audioQueue.sync {
            pipelineActive = false
            sessionAPIKey = nil
            lastVoiceAt.removeAll()
            silenceTailRemaining.removeAll()
            appendPaused.removeAll()
            preRoll.removeAll()
            for (_, client) in clients { client.close() }
            clients.removeAll()
            resamplers.removeAll()
        }
        sessionStates.removeAll()
        reconnectAttempts.removeAll()
        sessionOpenedAt.removeAll()
        pipelineStatuses = []
        resetPlaybackState()
        refreshCost()
        metrics.endSession()
        Log.info("Conversation stopped")
    }

    /// Single source of truth for `isIdleTimerDisabled`. iOS silently resets
    /// the flag to false whenever the app is deactivated (app switch, incoming
    /// call, Siri, lock button), so a one-shot assignment does not survive a
    /// trip through the background — the scene reasserts this on every return
    /// to `.active`. The screen is kept awake whenever the user asked for it
    /// app-wide, or whenever audio is live (starting/bench/conversation):
    /// letting the screen sleep mid-session suspends the app and drops every
    /// open translation session.
    func applyIdleTimerPolicy() {
        UIApplication.shared.isIdleTimerDisabled = AppSettings.keepScreenAwake || mode != .idle
    }

    private func buildResamplers(channelCount: Int) {
        let rate = engineGraph.inputSampleRate
        audioQueue.sync {
            resamplers.removeAll()
            warnedMissingResampler.removeAll()
            // Fresh converters mean a fresh append timeline: stale pause/tail
            // state must not splice a pre-rebuild pre-roll into it.
            silenceTailRemaining.removeAll()
            appendPaused.removeAll()
            preRoll.removeAll()
            for channel in 0..<channelCount {
                resamplers[channel] = StreamResampler(inputSampleRate: rate)
            }
        }
    }

    /// Player nodes are torn down on every engine rebuild and their pending
    /// completion handlers may never fire — reset the counters that ducking
    /// keys off, or they wedge.
    private func resetPlaybackState() {
        pendingPlaybackBuffers.removeAll()
    }

    // MARK: - Input pipeline

    private func installInputHandler() {
        engineGraph.onInputChannels = { [weak self] channelPointers, frames, sampleRate in
            guard let self else { return }
            // Copy on the tap thread — the pointers die when the callback
            // returns — then process off-thread.
            let laneCount = min(4, channelPointers.count)
            var buffers: [AVAudioPCMBuffer] = []
            for index in 0..<laneCount {
                guard let buffer = EngineGraph.monoBuffer(from: channelPointers[index], frames: frames, sampleRate: sampleRate) else { return }
                buffers.append(buffer)
            }
            self.audioQueue.async { self.processConversationBuffers(buffers, frames: frames, sampleRate: sampleRate) }
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
            guard let resampler = resamplers[channel] else {
                if speech, warnedMissingResampler.insert(channel).inserted {
                    Log.error("ch\(channel): gate passed speech but no resampler exists — audio is being dropped before the session (engine/route rebuild mismatch)")
                }
                continue
            }
            // The real audio is resampled on every buffer — sent or not — so
            // the converter's filter state stays gapless and the freshest
            // 200 ms is always available as pre-roll.
            guard let data = resampler.convert(buffers[channel]) else { continue }
            if !decision.pass { preRoll[channel] = data }
            let existingClient = clients[channel]
            guard let client = existingClient ?? lazyOpenSession(channel: channel, speech: speech) else {
                // No session: nothing owes a tail and there is nothing to pause.
                silenceTailRemaining[channel] = nil
                appendPaused.remove(channel)
                continue
            }
            if decision.pass {
                let resumed = appendPaused.remove(channel) != nil
                if resumed || existingClient == nil {
                    // A fresh session's first append and a resumed stream both
                    // lead with the pre-roll; only a resume needs the quiet
                    // splice (a new session has no previous phrase to butt
                    // against). Oversized appends are fine — the server
                    // splits them into 200 ms frames itself.
                    var spliced = Data()
                    if resumed { spliced.append(Self.resumeSpliceSilence) }
                    if let pre = preRoll.removeValue(forKey: channel) { spliced.append(pre) }
                    spliced.append(data)
                    client.sendAudio(spliced, containsSpeech: speech)
                } else {
                    client.sendAudio(data, containsSpeech: speech)
                }
                silenceTailRemaining[channel] = Self.silenceTailBufferCount
            } else if let tail = silenceTailRemaining[channel], tail > 0 {
                silenceTailRemaining[channel] = tail - 1
                client.sendAudio(Data(count: data.count), containsSpeech: false)
            } else {
                appendPaused.insert(channel)
            }
        }
        pushMeters(decisions)
    }

    /// Runs on audioQueue. Opens a channel's translation session the first
    /// time genuine (non-bleed) speech is detected on it; the client queues
    /// audio while the socket connects, so the triggering words are
    /// translated too.
    private func lazyOpenSession(channel: Int, speech: Bool) -> RealtimeTranslationClient? {
        guard speech, pipelineActive, let apiKey = sessionAPIKey else { return nil }
        Log.info("Speech on channel \(channel) — opening translation session")
        let client = makeClient(lane: channel, outputLanguage: AppSettings.outputLanguage, apiKey: apiKey)
        clients[channel] = client
        client.connect()
        return client
    }

    private var lastMeterPush = Date.distantPast

    private func pushMeters(_ decisions: [ChannelGate.Decision]) {
        let now = Date()
        guard now.timeIntervalSince(lastMeterPush) > 0.1 else { return }
        lastMeterPush = now
        let levels = decisions.map { min(1, $0.rms * 12) }
        let open = decisions.map(\.pass)
        DispatchQueue.main.async {
            self.channelMeters.update(levels: levels, gateOpen: open)
        }
    }

    // MARK: - Sessions

    /// Create and wire a client without registering or connecting it.
    /// Safe to call from any thread (settings/keychain are thread-safe).
    private func makeClient(lane: Int, outputLanguage: String, apiKey: String) -> RealtimeTranslationClient {
        var config = SessionConfig(outputLanguage: outputLanguage)
        config.model = AppSettings.modelName
        config.noiseReduction = AppSettings.noiseReduction
        let client = RealtimeTranslationClient(
            label: "ch\(lane)→\(outputLanguage)",
            config: config,
            apiKey: apiKey,
            endpointTemplate: AppSettings.endpointTemplate
        )
        wireClient(client, lane: lane)
        return client
    }

    private func wireClient(_ client: RealtimeTranslationClient, lane: Int) {
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
        // Like onBilledSeconds, deliberately not identity-guarded: latency
        // measured on a client that was idle-closed mid-flight is still a
        // real measurement. MetricsStore is main-confined, so hop.
        client.onConnectSeconds = { [weak self] seconds in
            DispatchQueue.main.async { self?.metrics.recordConnect(lane: lane, seconds: seconds) }
        }
        client.onFirstResponseSeconds = { [weak self] seconds in
            DispatchQueue.main.async { self?.metrics.recordFirstResponse(lane: lane, seconds: seconds) }
        }
        client.onTranslatedAudio = { [weak self] audio in
            DispatchQueue.main.async { self?.playEnglishAudio(audio, lane: lane) }
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
        let othersActive = pendingPlaybackBuffers.contains { $0.key != lane && $0.value > 0 }
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
        channelMeters.reset(channelCount: channelCount)
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

    /// Quiet window before an open bubble finalizes. The short variant
    /// applies when both streams already end on a sentence boundary —
    /// dinner-table turn-taking needs closes to keep pace with the
    /// conversation, and reopenRecentIfNeeded covers the rare late delta.
    private static let finalizeTimeout: TimeInterval = 2.5
    private static let finalizeSentenceTimeout: TimeInterval = 1.0

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshCost()
            self.closeIdleSessions()
            self.watchdogEngineCheck()
            self.refreshPipelineStatuses()
        }
        // Finalization runs on its own 4 Hz timer so bubble closes track the
        // quiet timeout instead of the 1 Hz UI tick. Cheap when nothing is
        // ready: Date math over at most 4 open lanes, no @Published churn.
        finalizeTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.transcript.finalizeStale(
                timeout: Self.finalizeTimeout,
                completedSentenceTimeout: Self.finalizeSentenceTimeout
            )
            // The prompter's ambient trigger keys off finalizations (plus
            // the immediate sentence-boundary callback) — tick right after
            // finalizeStale so a fresh utterance can fire a suggestion
            // request without waiting on the 1 Hz tick (docs/REPLY-FLOW.md
            // §3). Both counters are monotonic, so the trigger survives the
            // transcript's 400-utterance trim cap.
            if self.mode == .conversation {
                self.assist.transcriptTick(contentEvents: self.transcript.finalizedTotal + self.transcript.sentenceEventTotal)
            }
        }
        timer.tolerance = 0.1
        finalizeTimer = timer
    }

    /// Rebuild the Diagnostics pipeline rows from live client counters.
    /// Main thread (UI timer); each snapshot() is a brief sync hop onto that
    /// client's queue, and the clients dictionary is copied under audioQueue.
    private func refreshPipelineStatuses() {
        guard mode == .conversation else {
            if !pipelineStatuses.isEmpty { pipelineStatuses = [] }
            return
        }
        let (clientsCopy, voiceTimes) = audioQueue.sync { (clients, lastVoiceAt) }
        let sessionSnapshots = clientsCopy.mapValues { $0.snapshot() }
        let now = Date()
        let open = channelMeters.gateOpen
        pipelineStatuses = lanes.map { lane in
            LanePipelineStatus(
                id: lane.id,
                name: lane.name,
                gateOpen: lane.id < open.count ? open[lane.id] : false,
                secondsSinceSpeech: voiceTimes[lane.id].map { now.timeIntervalSince($0) },
                session: sessionSnapshots[lane.id]
            )
        }
        // The Metrics tab samples the same 1 Hz snapshots the pipeline
        // panel reads — no extra client-queue hops. Lane names ride along so
        // MetricsView never has to observe AppModel (whose meters churn at
        // 10 Hz and would re-render every chart at meter rate).
        metrics.sample(
            realtimeCost: costMeter.estimatedDollars,
            lanes: sessionSnapshots,
            laneNames: Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0.name) })
        )
    }

    /// AVAudioEngine auto-stops on configuration changes (Bluetooth codec
    /// renegotiation, USB glitches) and interruptions, and before this
    /// watchdog nothing ever restarted it — the classic "playback never
    /// continues after a pause" failure. Restart it whenever it's found dead
    /// outside an active interruption.
    private func watchdogEngineCheck() {
        guard mode == .conversation || mode == .bench, !engineGraph.engine.isRunning else { return }
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
    /// for quiet channels. Sessions on mics disabled in Settings close
    /// immediately, timeout or not.
    private func closeIdleSessions() {
        guard mode != .idle else { return }
        let timeout = AppSettings.idleCloseSeconds
        let now = Date()
        var closedLanes: [Int] = []
        var disabledLanes: Set<Int> = []
        audioQueue.sync {
            for (lane, client) in clients {
                if !AppSettings.speakerEnabled(lane) {
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
        // @Published fires objectWillChange even on same-value writes, and
        // this runs at 1 Hz — only publish when the estimate actually moved.
        let cost = costMeter.estimatedDollars
        if estimatedCost != cost { estimatedCost = cost }
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
        guard mode == .conversation || mode == .bench else { return }
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
            try engineGraph.start(playerCount: mode == .bench ? 1 : playbackLaneCount)
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
