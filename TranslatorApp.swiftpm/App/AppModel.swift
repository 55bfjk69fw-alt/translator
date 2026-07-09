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
    @Published private(set) var sessionStates: [Int: RealtimeTranslationClient.State] = [:]
    @Published private(set) var route: AudioSessionController.RouteSnapshot?
    @Published private(set) var estimatedCost: Double = 0
    @Published var errorBanner: String?
    @Published private(set) var speakerOverrideActive = false
    @Published private(set) var pttLevel: Float = 0

    let transcript: TranscriptStore
    let log = Log.shared

    // MARK: - Pipeline components

    let audioSession = AudioSessionController()
    private let engineGraph = EngineGraph()
    private let gate = ChannelGate()
    private let costMeter = CostMeter()
    private let audioQueue = DispatchQueue(label: "translator.audio.pipeline", qos: .userInitiated)

    /// laneID -> client. DJI lanes are 0..<channelCount; the user's
    /// push-to-talk lane is SpeakerLane.userLaneID.
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
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            errorBanner = "Add your OpenAI API key in Settings first."
            return
        }
        errorBanner = nil
        stopping = false

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
            gate.enabled = AppSettings.noiseGateEnabled
            gate.minimumVoiceThreshold = AppSettings.vadThreshold
            gate.reset()
            pipelineActive = true
            sessionAPIKey = apiKey
            lastVoiceAt.removeAll()
        }
        buildResamplers(channelCount: channelCount)
        // Sessions are opened lazily on first speech per channel, not here —
        // a disconnected/powered-off TX never opens a billed session.
        sessionStates = Dictionary(uniqueKeysWithValues: (0..<channelCount).map { ($0, RealtimeTranslationClient.State.idle) })

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
            lastVoiceAt.removeAll()
            for (_, client) in clients { client.close() }
            clients.removeAll()
            resamplers.removeAll()
        }
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
        let decisions = gate.evaluate(channels: channels, frames: frames, sampleRate: sampleRate)
        for (channel, decision) in decisions.enumerated() {
            // Keyed on pass (not voiced): bleed from another speaker must
            // neither open a session for this lane nor keep it alive.
            if decision.pass { lastVoiceAt[channel] = Date() }
            guard let resampler = resamplers[channel] else { continue }
            guard let client = clients[channel] ?? lazyOpenSession(channel: channel, speech: decision.pass) else { continue }
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
    private func lazyOpenSession(channel: Int, speech: Bool) -> RealtimeTranslationClient? {
        guard speech, pipelineActive, let apiKey = sessionAPIKey else { return nil }
        Log.info("Speech on channel \(channel) — opening translation session")
        let client = makeClient(lane: channel, outputLanguage: "en", apiKey: apiKey)
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

    /// Create and wire a client without registering or connecting it.
    /// Safe to call from any thread (settings/keychain are thread-safe).
    private func makeClient(lane: Int, outputLanguage: String, apiKey: String) -> RealtimeTranslationClient {
        var config = SessionConfig(outputLanguage: outputLanguage)
        config.model = AppSettings.modelName
        let label = lane == SpeakerLane.userLaneID ? "me→zh" : "ch\(lane)→\(outputLanguage)"
        let client = RealtimeTranslationClient(
            label: label,
            config: config,
            apiKey: apiKey,
            endpointTemplate: AppSettings.endpointTemplate
        )
        wireClient(client, lane: lane)
        return client
    }

    /// Main-thread path (push-to-talk lane): register + connect.
    private func openClient(lane: Int, outputLanguage: String, apiKey: String) {
        let client = makeClient(lane: lane, outputLanguage: outputLanguage, apiKey: apiKey)
        audioQueue.sync { clients[lane] = client }
        client.connect()
    }

    private func wireClient(_ client: RealtimeTranslationClient, lane: Int) {
        let isUserLane = lane == SpeakerLane.userLaneID

        client.onStateChange = { [weak self, weak client] state in
            DispatchQueue.main.async {
                guard let self, let client else { return }
                // Ignore events from clients no longer registered for this
                // lane (e.g. after an idle-close) so they can't clobber the
                // lane's displayed state or trigger reconnects.
                guard self.audioQueue.sync(execute: { self.clients[lane] === client }) else { return }
                // Cost accounting keyed on the transition we observed, so a
                // handshake that fails before opening never double-decrements.
                let previous = self.sessionStates[lane]
                switch state {
                case .open:
                    if previous != .open { self.costMeter.sessionOpened() }
                    self.sessionOpenedAt[lane] = Date()
                case .closed:
                    if previous == .open { self.costMeter.sessionClosed() }
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

    // MARK: - English playback with overlap ducking (main thread)

    private func playEnglishAudio(_ audio: Data, lane: Int) {
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
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else { return }
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
                self.openClient(lane: SpeakerLane.userLaneID, outputLanguage: "zh", apiKey: apiKey)
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
        transcript.appendTranslatedAudio(lane: SpeakerLane.userLaneID, audio: audio, keepAudio: true)
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
        audioQueue.sync { gate.enabled = false }
        installInputHandler()
        // Bench mode has no clients; processConversationBuffers still runs
        // and drives the meters, sends go nowhere.
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
        }
    }

    /// Close sessions whose channel has been silent past the idle timeout —
    /// they reopen automatically on the next detected speech. Stops billing
    /// for quiet channels and for the PTT lane between uses.
    private func closeIdleSessions() {
        let timeout = AppSettings.idleCloseSeconds
        guard timeout > 0, mode != .idle else { return }
        let now = Date()
        var closedLanes: [Int] = []
        audioQueue.sync {
            for (lane, client) in clients {
                if lane == SpeakerLane.userLaneID && pttEngaged { continue }
                guard let last = lastVoiceAt[lane], now.timeIntervalSince(last) > timeout else { continue }
                clients[lane] = nil
                client.close()
                closedLanes.append(lane)
            }
        }
        for lane in closedLanes {
            sessionStates[lane] = .idle
            reconnectAttempts[lane] = 0
            Log.info("Closed idle session for \(laneName(lane)) (silent \(Int(timeout))s) — reopens on speech")
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
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshRoute()
        guard mode == .conversation, !pttEngaged else { return }
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
            Log.warn("Audio interruption began")
        case .ended:
            guard mode != .idle else { return }
            Log.info("Audio interruption ended — restarting engine")
            restartEngineForCurrentRoute()
        @unknown default:
            break
        }
    }

    private func restartEngineForCurrentRoute() {
        guard mode == .conversation else { return }
        engineGraph.stop()
        resetPlaybackState()
        do {
            try audioSession.configureForConversation()
            try engineGraph.start(playerCount: zhPlaybackLane + 1)
            buildResamplers(channelCount: lanes.count)
            audioQueue.sync { gate.reset() }
            refreshRoute()
        } catch {
            errorBanner = "Audio restart failed: \(error.localizedDescription)"
        }
    }
}
