import Foundation
import AVFoundation

/// LaneEngine adapter around RealtimeTranslationClient: one OpenAI
/// realtime translation session per lane, plus everything AppModel used to
/// do around it — resampling to the wire format, silence substitution for
/// gate-suppressed audio, and the reconnect loop with its banner.
///
/// The observable contract this must preserve, verbatim from the pre-seam
/// AppModel (docs/CASCADE-PIPELINE.md §5.1.1):
///  1. Indefinite retry with capped backoff min(30, 2^min(attempts, 5)),
///     bounded only by close() — a pending backoff timer inside a closed
///     engine no-ops.
///  2. The attempt counter resets only after a connection survives ≥ 5 s
///     open (an open-then-instant-reject loop must not retry with a fresh
///     counter forever).
///  3. On the 5th consecutive attempt, raise the "keeps failing" banner.
///  4. After 5 s of surviving open, retract the banner — only the banner
///     this lane raised (id-keyed on AppModel's side).
///  5. Billed cost flows through the close drain (onCostDelta is never
///     identity-guarded upstream).
///  6. Lazy open with the client's pre-open audio queue stays inside
///     RealtimeTranslationClient, untouched.
///
/// Threading: all mutable state is confined to `queue`. Client callbacks
/// (which fire on the client's own queue) hop here; public entry points
/// hop here; seam callbacks fire from here and consumers hop to main.
final class RealtimeLaneEngine: LaneEngine {

    // Realtime pricing (moved from CostMeter with the dollars conversion —
    // the seam carries dollars, and only this engine knows its rates).
    // Each session bills two lines on the same "realtime audio duration":
    // gpt-realtime-translate at $0.034/min, plus gpt-realtime-whisper
    // source transcription (requested by every session.update — see
    // SessionConfig) at roughly half that, derived from the owner's
    // 2026-07-12 dashboard ($8.40 whisper vs $17.00 translate on identical
    // billed minutes). Update both from the dashboard when OpenAI publishes
    // the whisper-in-translation rate. Calibration caveat: that dashboard
    // predates the send-path change that pauses appends while the gate is
    // closed; if translate (session clock) and whisper (appended audio)
    // minutes diverge under the pause regime, re-derive the ratio from the
    // first post-merge dashboard.
    static let dollarsPerSessionMinute = 0.034
    static let transcriptionDollarsPerSessionMinute = 0.0168
    static var combinedDollarsPerSessionMinute: Double {
        dollarsPerSessionMinute + transcriptionDollarsPerSessionMinute
    }

    let label: String

    var onState: ((LaneEngineState) -> Void)?
    var onNotice: ((LaneNotice) -> Void)?
    var onTranscript: ((TranscriptEvent) -> Void)?
    var onTranslatedAudio: ((Data) -> Void)?
    var onCostDelta: ((Double) -> Void)?
    var onMetric: ((LaneMetric) -> Void)?

    private let queue: DispatchQueue
    private let client: RealtimeTranslationClient
    /// Current speaker name for banner text; reads AppSettings
    /// (UserDefaults is thread-safe), so a mid-conversation rename shows
    /// in a later banner, as before.
    private let laneName: () -> String
    private let noticeID: String

    // MARK: - Queue-confined state

    private var closed = false
    private var everStarted = false
    private var resampler: StreamResampler?
    private var warnedMissingResampler = false
    private var reconnectAttempts = 0
    /// When the current connection reached .open; nil while not open.
    private var openedAt: Date?
    private var state: LaneEngineState = .idle {
        didSet {
            if state != oldValue { onState?(state) }
        }
    }

    init(
        lane: Int,
        outputLanguage: String,
        model: String,
        noiseReduction: String?,
        apiKey: String,
        endpointTemplate: String,
        laneName: @escaping () -> String
    ) {
        self.label = "ch\(lane)→\(outputLanguage)"
        self.laneName = laneName
        self.noticeID = "reconnect.\(lane)"
        self.queue = DispatchQueue(label: "translator.lane.realtime.\(lane)")
        var config = SessionConfig(outputLanguage: outputLanguage)
        config.model = model
        config.noiseReduction = noiseReduction
        self.client = RealtimeTranslationClient(
            label: label,
            config: config,
            apiKey: apiKey,
            endpointTemplate: endpointTemplate
        )
        wireClient()
    }

    // MARK: - LaneEngine (entry points hop onto the queue)

    func start() {
        queue.async {
            guard !self.closed, !self.everStarted else { return }
            self.everStarted = true
            self.state = .starting
            self.client.connect()
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.client.close()
            self.state = .idle
            // AppModel drops its strong reference at eviction and every
            // other hop to this engine is weak — but the client keeps
            // draining (and billing, and delivering final transcript
            // deltas) for up to 3 s after session.close, and those
            // callbacks route THROUGH this engine. Hold self past the
            // drain cap so the chain's middle link can't deallocate out
            // from under the "deliberately not identity-guarded" cost
            // contract (§5.1.1 item 5).
            self.queue.asyncAfter(deadline: .now() + 4) { _ = self }
        }
    }

    func sendAudio(_ buffer: AVAudioPCMBuffer, verdict: GateVerdict) {
        queue.async {
            guard !self.closed else { return }
            // Format self-healing (seam contract): route churn changes the
            // hardware rate mid-conversation, and the resampler must track
            // it — AppModel no longer rebuilds resamplers on route change.
            let rate = buffer.format.sampleRate
            if self.resampler == nil || self.resampler?.inputFormat.sampleRate != rate {
                if self.resampler != nil {
                    Log.info("[\(self.label)] input rate changed to \(Int(rate)) Hz — rebuilding resampler")
                }
                self.resampler = StreamResampler(inputSampleRate: rate)
                self.warnedMissingResampler = false
            }
            guard let resampler = self.resampler else {
                // A silent-drop path that otherwise looks exactly like
                // "gate open, nothing captured" — same one-shot warning the
                // pre-seam pipeline logged. (Ordering flip vs pre-seam: the
                // old code checked the resampler BEFORE lazy-open, so an
                // unconvertible lane never opened a billed session; now the
                // engine — and its socket — exists first. Pathological
                // case, and the warning is the evidence either way.)
                if verdict.speech, !self.warnedMissingResampler {
                    self.warnedMissingResampler = true
                    Log.error("[\(self.label)] gate passed speech but no resampler could be built for \(Int(rate)) Hz — audio is being dropped before the session")
                }
                return
            }
            // Suppressed audio becomes silence, not a gap: translation
            // sessions treat a send gap as contiguous audio, so the
            // timeline must stay continuous (the OpenAI-realtime contract
            // this engine exists to honor).
            let outgoing = verdict.pass
                ? buffer
                : EngineGraph.silentBuffer(frames: Int(buffer.frameLength), sampleRate: rate)
            if let outgoing, let data = resampler.convert(outgoing) {
                self.client.sendAudio(data, containsSpeech: verdict.speech)
            }
        }
    }

    func snapshot() -> LaneEngineSnapshot {
        // client.snapshot() syncs onto the client's queue; that queue never
        // syncs back onto this one, so the nesting can't deadlock.
        .realtime(client.snapshot())
    }

    // MARK: - Client wiring (callbacks hop from the client queue to ours)

    private func wireClient() {
        client.onStateChange = { [weak self] clientState in
            self?.queue.async { self?.handleClientState(clientState) }
        }
        client.onSourceTranscriptDelta = { [weak self] delta in
            self?.queue.async { self?.onTranscript?(.sourceDelta(delta)) }
        }
        client.onTranslatedTranscriptDelta = { [weak self] delta in
            self?.queue.async { self?.onTranscript?(.translationDelta(delta)) }
        }
        client.onTranslatedAudio = { [weak self] audio in
            self?.queue.async { self?.onTranslatedAudio?(audio) }
        }
        // Cost is forwarded straight from the client queue — the drain
        // must keep billing even while this engine is tearing down, and
        // the consumer (CostMeter) is thread-safe.
        client.onBilledSeconds = { [weak self] seconds in
            guard seconds > 0 else { return }
            self?.onCostDelta?(seconds / 60.0 * Self.combinedDollarsPerSessionMinute)
        }
        client.onConnectSeconds = { [weak self] seconds in
            self?.queue.async { self?.onMetric?(.connectSeconds(seconds)) }
        }
        client.onFirstResponseSeconds = { [weak self] seconds in
            self?.queue.async { self?.onMetric?(.firstResponseSeconds(seconds)) }
        }
    }

    /// Queue-confined: the reconnect state machine, moved verbatim from
    /// AppModel.wireClient + scheduleReconnectIfNeeded.
    private func handleClientState(_ clientState: RealtimeTranslationClient.State) {
        guard !closed else { return }
        switch clientState {
        case .idle:
            break
        case .connecting:
            // No state change needed: the first connect follows start()'s
            // .starting, and every reconnect follows scheduleReconnect()'s
            // .reconnecting — same yellow dot either way.
            break
        case .open:
            let opened = Date()
            openedAt = opened
            state = .running
            // A recovered lane must retract the lane's scare banner
            // promptly. 5 s of survival is the proof bar; the openedAt
            // identity check pins the timer to THIS open episode — note
            // this is deliberately stricter than the pre-seam code, which
            // could clear on the strength of a <5 s bounce-and-reopen.
            // The clear is emitted UNCONDITIONALLY (not only when this
            // instance raised a banner): the banner is lane-keyed, and a
            // failing engine can be evicted (idle-close during an outage,
            // mic toggled) taking its raised-flag with it — the
            // replacement engine must still retract the lane's stale
            // banner. AppModel no-ops a clear when nothing is raised.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.closed, self.openedAt == opened else { return }
                self.onNotice?(.cleared(id: self.noticeID))
            }
        case .closed:
            // Only a session that survived a while proves the config
            // works; resetting the attempt counter on every open would let
            // an open-then-instant-reject loop retry forever (contract
            // item 2).
            if let openedAt, Date().timeIntervalSince(openedAt) >= 5 {
                reconnectAttempts = 0
            }
            openedAt = nil
            scheduleReconnect()
        }
    }

    /// Queue-confined. Retries for as long as the engine lives — never
    /// gives up; the chain is bounded by close() alone (Stop and
    /// idle-close both end it), exactly like the pre-seam guard chain.
    private func scheduleReconnect() {
        guard !closed else { return }
        reconnectAttempts += 1
        let attempts = reconnectAttempts
        if attempts == 5 {
            onNotice?(.raised(
                id: noticeID,
                text: "Session for \(laneName()) keeps failing — still retrying every 30 s. Check the network; if the network is fine, check the API key and event log."
            ))
        }
        let delay = min(30, pow(2, Double(min(attempts, 5))))
        state = .reconnecting(attempt: attempts)
        Log.warn("Reconnecting \(laneName()) in \(Int(delay))s (attempt \(attempts))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed else { return }
            self.client.connect()
        }
    }
}
