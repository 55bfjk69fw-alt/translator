import Foundation

/// WebSocket client for one OpenAI realtime translation session.
///
/// Server event names are matched against several aliases because the
/// translation session event schema is newer than this client; any event we
/// don't recognize is logged so the schema can be corrected from
/// DiagnosticsView evidence rather than guesswork.
///
/// Threading: ALL mutable state is confined to `queue`, which is also the
/// underlying queue of the URLSession delegate queue. Delegate callbacks,
/// receive/send/ping completions, the ping timer, and the public entry
/// points (which hop onto it) are therefore mutually serialized — including
/// across reconnects, since the same queue backs every connection's
/// delegate callbacks. Two invariants this buys:
///  - Audio queued while connecting is flushed on open as one queue block,
///    so a chunk arriving mid-flush can neither jump ahead of the queued
///    speech nor strand itself in the pending buffer.
///  - Late callbacks from a cancelled connection are identity-checked
///    against the current task and dropped, so they can't clobber a newer
///    connection's state.
final class RealtimeTranslationClient: NSObject {

    enum State: Equatable {
        case idle
        case connecting
        case open
        case closed(String?)
    }

    let label: String
    private let config: SessionConfig
    private let apiKey: String
    private let endpointTemplate: String

    /// Confines all mutable state below; see the class comment.
    private let queue: DispatchQueue
    private let delegateQueue: OperationQueue

    // MARK: - State (queue-confined)

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: DispatchSourceTimer?
    private var intentionallyClosed = false
    /// Event types seen this connection; each is logged once so the log
    /// records the actual server schema without flooding.
    private var seenEventTypes: Set<String> = []

    /// Per-connection traffic counters. The periodic/closing summary lines
    /// are the primary evidence for "Chinese text missing" (source-transcript
    /// deltas never arrived) and "playback stopped" (audio frames stopped or
    /// the socket went half-dead) reports.
    private struct Stats {
        var audioChunksSent = 0
        var audioBytesSent = 0
        /// Bytes that actually carried signal. Deliberate silence arrives
        /// here as exact digital zeros (post-speech tails, resume splices,
        /// keepalives), so this split distinguishes "we streamed 60 s of
        /// audio" from "the server heard 8 s of speech" — the difference is
        /// what makes a quiet lane's empty transcript expected, not a bug.
        var speechBytesSent = 0
        var chunksQueuedPreOpen = 0
        var sendFailures = 0
        var sourceDeltas = 0
        var sourceChars = 0
        var translationDeltas = 0
        var translationChars = 0
        var audioFrames = 0
        var audioBytes = 0
        var heartbeatsDropped = 0
        var keepalivesSent = 0
    }
    private var stats = Stats()
    private var lastServerEventAt = Date()
    /// When audio was last appended (queue-confined). With gate-closed
    /// pauses upstream, a quiet lane appends nothing for minutes; the ping
    /// tick sends one silent chunk past this age so intermediaries can't
    /// idle out the upstream half of the socket.
    private var lastAppendAt = Date()
    private static let keepaliveSilence = Data(count: 9_600) // 200 ms @ 24 kHz PCM16
    private var connectStartedAt: Date?
    private var openedAt: Date?
    private var pingTicks = 0

    /// What the server's session.updated ack said about source transcription.
    /// This is the definitive evidence for "translated audio arrives but the
    /// source-language (Chinese) text never does": if the ack doesn't echo an
    /// input transcription config, the server is not transcribing the source
    /// and no amount of waiting will produce that text.
    enum TranscriptionAck: Equatable {
        /// No session.updated ack seen yet this connection.
        case notReceived
        /// The ack echoed an input transcription config.
        case confirmed(String)
        /// The ack parsed but carried no input transcription config.
        case absent
        /// The ack arrived in a shape we couldn't parse; payload is in the log.
        case unparseable

        var summary: String {
            switch self {
            case .notReceived: return "no server ack yet"
            case .confirmed(let model): return "confirmed (\(model))"
            case .absent: return "absent from server ack"
            case .unparseable: return "ack unparseable (see log)"
            }
        }
    }
    private var transcriptionAck: TranscriptionAck = .notReceived
    /// When each server stream last produced content (heartbeats excluded).
    private var lastSourceDeltaAt: Date?
    private var lastTranslationDeltaAt: Date?
    private var lastAudioFrameAt: Date?
    /// Once-per-connection symptom flags so checkStreamSymptoms warns early
    /// (first ping tick after enough speech) without repeating every 20 s.
    private var warnedNothingReturned = false
    private var warnedNoSourceText = false
    private var warnedNoTranslatedAudio = false
    private var warnedNoAck = false

    /// 24 kHz mono PCM16 → billed audio bytes per second, both directions.
    private static let billedBytesPerSecond = 48_000.0
    /// Highest `elapsed_ms` seen on any server event this connection — the
    /// server's own session-audio clock, which is the billing basis
    /// ("realtime audio duration"). Advances ~5×/s via heartbeat frames,
    /// including while the server drains output after session.close.
    private var maxElapsedMs: Double = 0
    /// Billed seconds already delivered to onBilledSeconds this connection,
    /// so progress is reported as monotonic increments.
    private var reportedBilledSeconds: Double = 0

    /// First-response clock (queue-confined): armed by the first chunk the
    /// gate marked as speech that arrives while the server is quiet, cleared
    /// by the first content event back. The interval is the listener's
    /// time-to-first-response — for a lazily-opened session it includes the
    /// connect and the pre-open queue flush, which is exactly the delay the
    /// user feels.
    private var awaitingResponseSince: Date?
    /// When the server last produced content on any stream (heartbeats
    /// excluded) — a speech chunk only arms a fresh measurement once the
    /// server has been quiet, so mid-stream chunks don't count as "waits".
    private var lastContentEventAt: Date?
    /// Regenerated on every connect. Snapshot consumers diff the cumulative
    /// traffic counters between samples; comparing this identity is how they
    /// detect a counter reset — a value dip can't be trusted for that, since
    /// a reconnect's pre-open queue flush can outrun the old total within
    /// one sampling tick.
    private var connectionID = UUID()

    // Audio arriving while the socket is still connecting is queued and
    // flushed on open, so lazily-opened sessions don't drop the words that
    // triggered them. Bounded to ~30 s of 24 kHz PCM16.
    private var pendingAudio: [Data] = []
    private var pendingBytes = 0
    private let maxPendingBytes = 1_500_000
    private(set) var state: State = .idle {
        didSet {
            // A drop fires both the receive-failure path and didCloseWith;
            // collapse closed->closed so observers see one transition.
            if case .closed = oldValue, case .closed = state { return }
            if case .closed = state { logSummary(context: "closing") }
            onStateChange?(state)
        }
    }

    // Callbacks fire on the client's private queue; consumers hop to main
    // as needed.
    // Note: translation sessions emit NO done/completed transcript events and
    // no segment boundaries — deltas are append-only, ordered, correlated
    // only by elapsed_ms. Utterance segmentation is the consumer's job
    // (quiet-timeout in TranscriptStore).
    var onStateChange: ((State) -> Void)?
    var onSourceTranscriptDelta: ((String) -> Void)?
    var onTranslatedTranscriptDelta: ((String) -> Void)?
    /// 24 kHz mono PCM16 little-endian audio of the translated speech.
    var onTranslatedAudio: ((Data) -> Void)?
    /// Incremental billed-audio seconds: the best estimate of this
    /// connection's billed duration advanced by this much. The estimate is
    /// max(server elapsed_ms, input audio appended), so it keeps counting
    /// through the post-close drain and the pre-open queue flush.
    var onBilledSeconds: ((Double) -> Void)?
    /// WebSocket connect duration (connect() → 101 upgrade), once per open.
    var onConnectSeconds: ((Double) -> Void)?
    /// Speech-to-first-response latency, once per utterance burst (see
    /// awaitingResponseSince).
    var onFirstResponseSeconds: ((Double) -> Void)?

    // MARK: - Live snapshot (any thread)

    /// Everything the Diagnostics pipeline panel needs to say where the
    /// gate → session → transcript chain is breaking for this lane.
    struct Snapshot {
        var state: State
        /// Changes on every reconnect; counters below restart at zero with
        /// it. Consumers diffing counters across snapshots must treat a new
        /// ID as a fresh baseline.
        var connectionID: UUID
        /// Seconds since the socket reached .open (nil while not open).
        var openForSeconds: TimeInterval?
        /// Total audio streamed vs. the part that carried actual signal.
        var audioSecondsSent: Double
        var speechSecondsSent: Double
        var chunksQueuedPreOpen: Int
        var sendFailures: Int
        var sourceDeltas: Int
        var sourceChars: Int
        var translationDeltas: Int
        var translationChars: Int
        var audioFrames: Int
        var audioSecondsReceived: Double
        var secondsSinceLastServerEvent: TimeInterval
        /// nil = that stream has produced nothing this connection.
        var secondsSinceLastSourceDelta: TimeInterval?
        var secondsSinceLastTranslationDelta: TimeInterval?
        var secondsSinceLastAudioFrame: TimeInterval?
        var transcriptionAck: TranscriptionAck
    }

    /// Point-in-time copy of the connection's counters. Synchronous hop onto
    /// the client queue; safe from main (the queue never blocks on main).
    func snapshot() -> Snapshot {
        queue.sync {
            let now = Date()
            return Snapshot(
                state: state,
                connectionID: connectionID,
                openForSeconds: state == .open ? openedAt.map { now.timeIntervalSince($0) } : nil,
                audioSecondsSent: Double(stats.audioBytesSent) / Self.billedBytesPerSecond,
                speechSecondsSent: Double(stats.speechBytesSent) / Self.billedBytesPerSecond,
                chunksQueuedPreOpen: stats.chunksQueuedPreOpen,
                sendFailures: stats.sendFailures,
                sourceDeltas: stats.sourceDeltas,
                sourceChars: stats.sourceChars,
                translationDeltas: stats.translationDeltas,
                translationChars: stats.translationChars,
                audioFrames: stats.audioFrames,
                audioSecondsReceived: Double(stats.audioBytes) / Self.billedBytesPerSecond,
                secondsSinceLastServerEvent: now.timeIntervalSince(lastServerEventAt),
                secondsSinceLastSourceDelta: lastSourceDeltaAt.map { now.timeIntervalSince($0) },
                secondsSinceLastTranslationDelta: lastTranslationDeltaAt.map { now.timeIntervalSince($0) },
                secondsSinceLastAudioFrame: lastAudioFrameAt.map { now.timeIntervalSince($0) },
                transcriptionAck: transcriptionAck
            )
        }
    }

    init(label: String, config: SessionConfig, apiKey: String, endpointTemplate: String) {
        self.label = label
        self.config = config
        self.apiKey = apiKey
        self.endpointTemplate = endpointTemplate
        let queue = DispatchQueue(label: "translator.ws.client")
        self.queue = queue
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue
        super.init()
    }

    // MARK: - Lifecycle (public entry points hop onto the queue)

    func connect() {
        queue.async { self.connectOnQueue() }
    }

    /// Graceful shutdown: session.close asks the server to flush pending
    /// input and emit remaining translated output; we keep reading until the
    /// session.closed ack (bounded by a timeout) — dropping the socket
    /// immediately loses output still draining from the session.
    func close() {
        queue.async { self.closeOnQueue() }
    }

    /// Append 24 kHz mono PCM16 audio to the session's input buffer.
    /// Translation sessions accept exactly: session.update,
    /// session.input_audio_buffer.append, session.close — note the
    /// "session." prefix on all client events.
    ///
    /// `containsSpeech` is the gate's voicing verdict for this chunk; it
    /// drives the first-response clock. Keyed on the gate (not a silence
    /// scan here) so that with the gate disabled — where every noisy room
    /// buffer flows through — ambient noise can't arm bogus latency
    /// measurements.
    func sendAudio(_ pcm16: Data, containsSpeech: Bool = false) {
        queue.async { self.sendAudioOnQueue(pcm16, containsSpeech: containsSpeech) }
    }

    // MARK: - Lifecycle (queue-confined)

    private func connectOnQueue() {
        guard state == .idle || stateIsClosed else { return }
        guard let url = config.url(endpointTemplate: endpointTemplate) else {
            state = .closed("Bad endpoint URL")
            return
        }
        intentionallyClosed = false
        seenEventTypes.removeAll()
        stats = Stats()
        connectionID = UUID()
        // Each connection is a fresh billed session server-side: elapsed_ms
        // restarts at zero, so the billed-progress baseline must too.
        maxElapsedMs = 0
        reportedBilledSeconds = 0
        lastServerEventAt = Date()
        connectStartedAt = Date()
        openedAt = nil
        pingTicks = 0
        transcriptionAck = .notReceived
        lastSourceDeltaAt = nil
        lastTranslationDeltaAt = nil
        lastAudioFrameAt = nil
        // pendingAudio survives a reconnect and flushes on open, so a wait
        // armed by still-queued speech keeps its clock (the reconnect delay
        // IS part of what the listener waits through). A wait with nothing
        // queued was armed by audio that died with the old socket — clearing
        // it stops the measurement from including a whole outage.
        if pendingAudio.isEmpty { awaitingResponseSince = nil }
        lastContentEventAt = nil
        warnedNothingReturned = false
        warnedNoSourceText = false
        warnedNoTranslatedAudio = false
        warnedNoAck = false
        state = .connecting

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Do NOT send "OpenAI-Beta: realtime=v1": it marks the connection as
        // the retired beta protocol and the server rejects it with
        // beta_api_shape_disabled (beta shut down 2026-05-12).

        // URLSession retains its delegate until invalidated; reconnects must
        // release the previous session or every retry leaks one. Late
        // callbacks from the cancelled connection still land on this queue
        // and are dropped by the task-identity checks below.
        urlSession?.invalidateAndCancel()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        urlSession = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    private func closeOnQueue() {
        guard !intentionallyClosed else { return }
        intentionallyClosed = true
        stopPing()
        if state == .open {
            sendJSON(["type": "session.close"])
            // Identity-guarded so the timeout can only tear down the
            // connection it was armed for, never a later one.
            let draining = task
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, draining === self.task else { return }
                self.forceClose()
            }
        } else {
            forceClose()
        }
    }

    /// Queue-confined. Reachable from the session.closed ack, the
    /// drain-timeout, and closeOnQueue; idempotent.
    private func forceClose() {
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if state != .idle { state = .closed(nil) }
    }

    private var stateIsClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    // MARK: - Sending (queue-confined)

    private func sendAudioOnQueue(_ pcm16: Data, containsSpeech: Bool) {
        // Appending after session.close is a protocol violation.
        guard !intentionallyClosed else { return }
        // Armed here (not in sendAppendEvent) so audio queued while the
        // socket connects starts the clock at speech time, not flush time.
        if containsSpeech { armResponseClock() }
        if state == .open {
            sendAppendEvent(pcm16)
        } else {
            pendingAudio.append(pcm16)
            pendingBytes += pcm16.count
            while pendingBytes > maxPendingBytes, !pendingAudio.isEmpty {
                pendingBytes -= pendingAudio.removeFirst().count
            }
            stats.chunksQueuedPreOpen += 1
        }
    }

    private func sendAppendEvent(_ pcm16: Data) {
        stats.audioChunksSent += 1
        stats.audioBytesSent += pcm16.count
        lastAppendAt = Date()
        // Gate-suppressed audio is exact zeros, so the scan cleanly splits
        // "keeping the timeline alive" from "sending the server speech".
        if !Self.isPureSilence(pcm16) {
            stats.speechBytesSent += pcm16.count
        }
        sendJSON([
            "type": "session.input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ])
        reportBilledProgress()
    }

    /// Queue-confined. Billed duration is "realtime audio duration"; the
    /// best live estimate is the max of the server's session clock and the
    /// audio we've appended (audio queued while connecting flushes as a
    /// burst, so bytes sent can briefly lead the server clock, and the
    /// server clock keeps running through engine stalls and the close
    /// drain). Emits only the monotonic increment.
    private func reportBilledProgress() {
        let billed = max(maxElapsedMs / 1000.0,
                         Double(stats.audioBytesSent) / Self.billedBytesPerSecond)
        guard billed > reportedBilledSeconds else { return }
        let delta = billed - reportedBilledSeconds
        reportedBilledSeconds = billed
        onBilledSeconds?(delta)
    }

    /// Queue-confined. Start the first-response clock if this speech chunk
    /// begins a fresh request cycle (server quiet, no wait already pending).
    private func armResponseClock() {
        let now = Date()
        if let armed = awaitingResponseSince {
            // A burst the server never answered: re-arm rather than letting
            // one lost response poison every later measurement.
            if now.timeIntervalSince(armed) > 30 { awaitingResponseSince = now }
            return
        }
        // While the server is actively streaming a response, further speech
        // chunks are continuation, not a new wait.
        if let last = lastContentEventAt, now.timeIntervalSince(last) < 1.5 { return }
        awaitingResponseSince = now
    }

    /// Queue-confined. Called for every content event (heartbeats excluded):
    /// resolves a pending first-response measurement and marks the server as
    /// actively streaming.
    private func noteContentEvent() {
        let now = Date()
        if let armed = awaitingResponseSince {
            awaitingResponseSince = nil
            onFirstResponseSeconds?(now.timeIntervalSince(armed))
        }
        lastContentEventAt = now
    }

    static func isPureSilence(_ pcm16: Data) -> Bool {
        pcm16.withUnsafeBytes { raw in
            !raw.bindMemory(to: Int16.self).contains { $0 != 0 }
        }
    }

    private func flushPendingAudio() {
        let queued = pendingAudio
        pendingAudio.removeAll()
        pendingBytes = 0
        if !queued.isEmpty {
            let bytes = queued.reduce(0) { $0 + $1.count }
            Log.info("[\(label)] flushing \(queued.count) chunks (\(bytes / 1024)KB) queued while connecting")
        }
        for chunk in queued { sendAppendEvent(chunk) }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            // Completion runs on the delegate queue (= self.queue).
            guard let error, let self, task === self.task, !self.intentionallyClosed else { return }
            self.stats.sendFailures += 1
            // A failed send means the socket is broken even though receive()
            // may hang without erroring — fail fast so the lane reconnects
            // instead of staying "open" and permanently silent.
            self.failConnection("WS send failed: \(error.localizedDescription)")
        }
    }

    /// Queue-confined. Tear down a connection we've decided is dead (failed
    /// send/ping, event stall) so the closed state triggers AppModel's
    /// reconnect path.
    private func failConnection(_ reason: String) {
        guard !intentionallyClosed, !stateIsClosed else { return }
        Log.error("[\(label)] \(reason) — dropping socket to trigger reconnect")
        stopPing()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        state = .closed(reason)
    }

    // MARK: - Receiving (queue-confined)

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            // Completion runs on the delegate queue (= self.queue). A late
            // result from a replaced connection must not touch state.
            guard let self, task === self.task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleEventText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleEventText(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                if !self.intentionallyClosed {
                    Log.error("[\(self.label)] WS receive failed: \(error.localizedDescription)")
                    self.stopPing()
                    self.state = .closed(error.localizedDescription)
                }
            }
        }
    }

    // Translation sessions emit exactly seven server events (per the API
    // reference): error, session.created, session.updated, session.closed,
    // session.input_transcript.delta, session.output_transcript.delta,
    // session.output_audio.delta. Text/audio payloads are all in "delta".
    private func handleEventText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            Log.warn("[\(label)] Unparseable WS message (\(text.prefix(500)))")
            return
        }

        if seenEventTypes.insert(type).inserted {
            Log.info("[\(label)] first \(type)")
        }
        lastServerEventAt = Date()

        // Every delta event (heartbeat frames included) carries the
        // session-audio timestamp; parsed for all types defensively.
        if let elapsed = (object["elapsed_ms"] as? NSNumber)?.doubleValue,
           elapsed > maxElapsedMs {
            maxElapsedMs = elapsed
            reportBilledProgress()
        }

        switch type {
        case "session.output_audio.delta":
            // The stream interleaves pure-zero heartbeat frames (~every
            // 200 ms) with content frames. Filter by exact zero-amplitude —
            // not RMS (clips quiet speech) and not frame length (observed to
            // change server-side without notice).
            if let base64 = object["delta"] as? String,
               let audio = Data(base64Encoded: base64) {
                if Self.isPureSilence(audio) {
                    stats.heartbeatsDropped += 1
                } else {
                    stats.audioFrames += 1
                    stats.audioBytes += audio.count
                    lastAudioFrameAt = Date()
                    noteContentEvent()
                    onTranslatedAudio?(audio)
                }
            }
        case "session.input_transcript.delta":
            if let delta = object["delta"] as? String {
                stats.sourceDeltas += 1
                stats.sourceChars += delta.count
                lastSourceDeltaAt = Date()
                noteContentEvent()
                onSourceTranscriptDelta?(delta)
            }
        case "session.output_transcript.delta":
            if let delta = object["delta"] as? String {
                stats.translationDeltas += 1
                stats.translationChars += delta.count
                lastTranslationDeltaAt = Date()
                noteContentEvent()
                onTranslatedTranscriptDelta?(delta)
            }
        case "session.created", "session.updated":
            // Full payload, not just the type: the ack is the only place the
            // server states which config it actually applied, and a missing
            // input-transcription echo is the root cause behind "translated
            // audio but no source text".
            Log.info("[\(label)] \(type): \(text.prefix(1500))")
            if type == "session.updated" { recordSessionAck(object) }
        case "session.closed":
            // Server finished draining after our session.close — safe to
            // drop the socket now instead of waiting out the timeout.
            Log.info("[\(label)] session.closed (output drained)")
            forceClose()
        case "error":
            // Full payload: this is the primary evidence for protocol fixes.
            Log.error("[\(label)] Server error: \(text.prefix(2000))")
        default:
            Log.info("[\(label)] Unhandled event \(type): \(text.prefix(2000))")
        }
    }

    /// Queue-confined. Inspect a session.updated ack for the source
    /// transcription config we requested in session.update. The event schema
    /// is newer than this client, so both the GA nesting
    /// (session.audio.input.transcription) and the older flat key
    /// (session.input_audio_transcription) are accepted.
    private func recordSessionAck(_ object: [String: Any]) {
        guard let session = object["session"] as? [String: Any] else {
            transcriptionAck = .unparseable
            Log.warn("[\(label)] session.updated ack has no parseable session object — cannot verify transcription config (payload logged above)")
            return
        }
        let gaShape = (session["audio"] as? [String: Any])
            .flatMap { $0["input"] as? [String: Any] }
            .flatMap { $0["transcription"] as? [String: Any] }
        let legacyShape = session["input_audio_transcription"] as? [String: Any]
        if let transcription = gaShape ?? legacyShape {
            let model = transcription["model"] as? String ?? "model unspecified"
            transcriptionAck = .confirmed(model)
            Log.info("[\(label)] server ack confirms source transcription (\(model)) — source text should arrive")
        } else {
            transcriptionAck = .absent
            Log.warn("[\(label)] session.updated ack carries NO source transcription config — the server will send translation only, source (Chinese) text will never arrive for this connection; check the transcription model in SessionConfig against the logged ack payload")
        }
    }

    // MARK: - Keepalive (queue-confined)

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.pingTick() }
        timer.resume()
        pingTimer = timer
    }

    private func pingTick() {
        guard state == .open else { return }
        // The server sends events continuously while a session is
        // healthy (heartbeat audio frames every ~200 ms). A long
        // event gap on an "open" socket means it's half-dead —
        // receive() can hang for minutes without erroring, and a
        // lost pong never invokes the sendPing handler either.
        let eventGap = Date().timeIntervalSince(lastServerEventAt)
        if eventGap > 75 {
            failConnection("no server events for \(Int(eventGap))s — connection presumed dead")
            return
        }
        pingTicks += 1
        checkStreamSymptoms()
        if Date().timeIntervalSince(lastAppendAt) > 20 {
            stats.keepalivesSent += 1
            sendAppendEvent(Self.keepaliveSilence)
        }
        if pingTicks % 3 == 0 { logSummary(context: "periodic") }
        guard let task else { return }
        task.sendPing { [weak self] error in
            guard let self, let error, task === self.task else { return }
            self.failConnection("ping failed: \(error.localizedDescription)")
        }
    }

    /// One-line traffic summary, logged every ~60 s while open and once on
    /// close. Reads as: what we sent vs. what each server stream returned.
    private func logSummary(context: String) {
        let s = stats
        // A handshake that never carried traffic has nothing to summarize.
        guard s.audioChunksSent + s.chunksQueuedPreOpen + s.sourceDeltas
            + s.translationDeltas + s.audioFrames + s.heartbeatsDropped > 0 else { return }
        var line = "sent \(s.audioChunksSent) chunks/\(s.audioBytesSent / 1024)KB"
        if s.chunksQueuedPreOpen > 0 { line += " (\(s.chunksQueuedPreOpen) queued pre-open)" }
        if s.sendFailures > 0 { line += " (\(s.sendFailures) SEND FAILURES)" }
        line += "; recv source \(s.sourceDeltas)Δ/\(s.sourceChars)ch"
        line += ", translation \(s.translationDeltas)Δ/\(s.translationChars)ch"
        line += ", audio \(s.audioFrames) frames/\(s.audioBytes / 1024)KB"
        line += ", \(s.heartbeatsDropped) heartbeats dropped"
        if s.keepalivesSent > 0 { line += ", \(s.keepalivesSent) keepalives" }
        line += String(format: "; speech sent %.0fs of %.0fs total",
                       Double(s.speechBytesSent) / Self.billedBytesPerSecond,
                       Double(s.audioBytesSent) / Self.billedBytesPerSecond)
        // Compare against the OpenAI usage dashboard to validate the meter.
        line += String(format: "; billed ~%.0fs (server clock %.0fs, sent %.0fs)",
                       reportedBilledSeconds,
                       maxElapsedMs / 1000.0,
                       Double(s.audioBytesSent) / Self.billedBytesPerSecond)
        Log.info("[\(label)] stats (\(context)): \(line)")
    }

    /// Queue-confined, runs every ping tick (20 s). The live answer to "the
    /// gate is open but nothing shows up in the conversation": once ~10 s of
    /// actual speech (not gate-silence) has been sent, each broken-stream
    /// signature is called out once per connection, naming what it means for
    /// the UI instead of leaving the user to diff counters.
    private func checkStreamSymptoms() {
        let speechSeconds = Double(stats.speechBytesSent) / Self.billedBytesPerSecond
        guard speechSeconds >= 10 else { return }
        if !warnedNoAck, transcriptionAck == .notReceived {
            warnedNoAck = true
            Log.warn("[\(label)] session.update was never acked — the server may be running defaults (source transcription off); if source text is missing, this is why")
        }
        if stats.sourceDeltas + stats.translationDeltas + stats.audioFrames == 0 {
            if !warnedNothingReturned {
                warnedNothingReturned = true
                Log.warn("[\(label)] \(Int(speechSeconds))s of speech sent but NOTHING returned on any stream — audio is leaving the app and the session produces no output (wrong endpoint/config, or the gated audio is unintelligible; check the ack payloads above)")
            }
            return
        }
        if !warnedNoSourceText, stats.sourceDeltas == 0, stats.translationDeltas + stats.audioFrames > 0 {
            warnedNoSourceText = true
            Log.warn("[\(label)] translation flowing but NO source-transcript deltas — source (Chinese) text will be missing; transcription \(transcriptionAck.summary)")
        }
        if !warnedNoTranslatedAudio, stats.audioFrames == 0, stats.sourceDeltas > 0 {
            warnedNoTranslatedAudio = true
            Log.warn("[\(label)] source transcript flowing but NO translated audio frames — playback will be silent for this lane")
        }
    }

    private func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }
}

extension RealtimeTranslationClient: URLSessionWebSocketDelegate {
    // All delegate callbacks run on delegateQueue (= self.queue); each is
    // identity-checked so late callbacks from a cancelled connection are
    // ignored.
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        let connectSeconds = connectStartedAt.map { Date().timeIntervalSince($0) }
        if let connectSeconds { onConnectSeconds?(connectSeconds) }
        let latency = connectSeconds.map { String(format: " (%.1fs)", $0) } ?? ""
        Log.info("[\(label)] WS open\(latency)")
        lastServerEventAt = Date()
        openedAt = Date()
        lastAppendAt = Date()
        // Marking open and flushing the pre-open queue is one queue block,
        // so concurrent sendAudio calls order strictly before or after it —
        // no chunk can overtake the queued speech or strand in the buffer.
        state = .open
        sendJSON(config.sessionUpdateEvent())
        flushPendingAudio()
        startPing()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        // A rejected handshake (401/403/404) surfaces here with the HTTP
        // status on task.response rather than as a WebSocket close frame.
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            Log.error("[\(label)] WS handshake HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
        }
        if let error, !intentionallyClosed {
            Log.warn("[\(label)] WS task completed with error: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard webSocketTask === task else { return }
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        if !intentionallyClosed {
            Log.warn("[\(label)] WS closed (\(closeCode.rawValue)) \(reasonText ?? "")")
        }
        stopPing()
        state = .closed(reasonText)
    }
}
