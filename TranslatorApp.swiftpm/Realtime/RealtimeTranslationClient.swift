import Foundation

/// WebSocket client for one OpenAI realtime translation session.
///
/// Server event names are matched against several aliases because the
/// translation session event schema is newer than this client; any event we
/// don't recognize is logged so the schema can be corrected from
/// DiagnosticsView evidence rather than guesswork.
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

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
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
        var chunksQueuedPreOpen = 0
        var sendFailures = 0
        var sourceDeltas = 0
        var sourceChars = 0
        var translationDeltas = 0
        var translationChars = 0
        var audioFrames = 0
        var audioBytes = 0
        var heartbeatsDropped = 0
    }
    private let statsLock = NSLock()
    private var stats = Stats()
    private var lastServerEventAt = Date()
    private var connectStartedAt: Date?
    private var pingTicks = 0

    // Audio arriving while the socket is still connecting is queued and
    // flushed on open, so lazily-opened sessions don't drop the words that
    // triggered them. Bounded to ~30 s of 24 kHz PCM16.
    private let pendingLock = NSLock()
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

    // Callbacks fire on an arbitrary queue; consumers hop to main as needed.
    // Note: translation sessions emit NO done/completed transcript events and
    // no segment boundaries — deltas are append-only, ordered, correlated
    // only by elapsed_ms. Utterance segmentation is the consumer's job
    // (quiet-timeout in TranscriptStore).
    var onStateChange: ((State) -> Void)?
    var onSourceTranscriptDelta: ((String) -> Void)?
    var onTranslatedTranscriptDelta: ((String) -> Void)?
    /// 24 kHz mono PCM16 little-endian audio of the translated speech.
    var onTranslatedAudio: ((Data) -> Void)?

    init(label: String, config: SessionConfig, apiKey: String, endpointTemplate: String) {
        self.label = label
        self.config = config
        self.apiKey = apiKey
        self.endpointTemplate = endpointTemplate
        super.init()
    }

    // MARK: - Lifecycle

    func connect() {
        guard state == .idle || stateIsClosed else { return }
        guard let url = config.url(endpointTemplate: endpointTemplate) else {
            state = .closed("Bad endpoint URL")
            return
        }
        intentionallyClosed = false
        seenEventTypes.removeAll()
        statsLock.lock()
        stats = Stats()
        lastServerEventAt = Date()
        statsLock.unlock()
        connectStartedAt = Date()
        pingTicks = 0
        state = .connecting

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Do NOT send "OpenAI-Beta: realtime=v1": it marks the connection as
        // the retired beta protocol and the server rejects it with
        // beta_api_shape_disabled (beta shut down 2026-05-12).

        // URLSession retains its delegate until invalidated; reconnects must
        // release the previous session or every retry leaks one.
        urlSession?.invalidateAndCancel()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    /// Graceful shutdown: session.close asks the server to flush pending
    /// input and emit remaining translated output; we keep reading until the
    /// session.closed ack (bounded by a timeout) — dropping the socket
    /// immediately loses output still draining from the session.
    func close() {
        guard !intentionallyClosed else { return }
        intentionallyClosed = true
        stopPing()
        if state == .open {
            sendJSON(["type": "session.close"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.forceClose()
            }
        } else {
            forceClose()
        }
    }

    private func forceClose() {
        // Serialized on main: reachable from the receive thread
        // (session.closed), the drain-timeout timer, and close() callers.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
            if self.state != .idle { self.state = .closed(nil) }
        }
    }

    private var stateIsClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    // MARK: - Sending

    /// Append 24 kHz mono PCM16 audio to the session's input buffer.
    /// Translation sessions accept exactly: session.update,
    /// session.input_audio_buffer.append, session.close — note the
    /// "session." prefix on all client events.
    func sendAudio(_ pcm16: Data) {
        // Appending after session.close is a protocol violation.
        guard !intentionallyClosed else { return }
        if state == .open {
            sendAppendEvent(pcm16)
        } else {
            pendingLock.lock()
            pendingAudio.append(pcm16)
            pendingBytes += pcm16.count
            while pendingBytes > maxPendingBytes, !pendingAudio.isEmpty {
                pendingBytes -= pendingAudio.removeFirst().count
            }
            pendingLock.unlock()
            statsLock.lock()
            stats.chunksQueuedPreOpen += 1
            statsLock.unlock()
        }
    }

    private func sendAppendEvent(_ pcm16: Data) {
        statsLock.lock()
        stats.audioChunksSent += 1
        stats.audioBytesSent += pcm16.count
        statsLock.unlock()
        sendJSON([
            "type": "session.input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ])
    }

    static func isPureSilence(_ pcm16: Data) -> Bool {
        pcm16.withUnsafeBytes { raw in
            !raw.bindMemory(to: Int16.self).contains { $0 != 0 }
        }
    }

    private func flushPendingAudio() {
        pendingLock.lock()
        let queued = pendingAudio
        pendingAudio.removeAll()
        pendingBytes = 0
        pendingLock.unlock()
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
            guard let error, let self, !self.intentionallyClosed else { return }
            self.statsLock.lock()
            self.stats.sendFailures += 1
            self.statsLock.unlock()
            // A failed send means the socket is broken even though receive()
            // may hang without erroring — fail fast so the lane reconnects
            // instead of staying "open" and permanently silent.
            self.failConnection("WS send failed: \(error.localizedDescription)")
        }
    }

    /// Tear down a connection we've decided is dead (failed send/ping, event
    /// stall) so the closed state triggers AppModel's reconnect path.
    private func failConnection(_ reason: String) {
        guard !intentionallyClosed, !stateIsClosed else { return }
        Log.error("[\(label)] \(reason) — dropping socket to trigger reconnect")
        stopPing()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        state = .closed(reason)
    }

    // MARK: - Receiving

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
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
        statsLock.lock()
        lastServerEventAt = Date()
        statsLock.unlock()

        switch type {
        case "session.output_audio.delta":
            // The stream interleaves pure-zero heartbeat frames (~every
            // 200 ms) with content frames. Filter by exact zero-amplitude —
            // not RMS (clips quiet speech) and not frame length (observed to
            // change server-side without notice).
            if let base64 = object["delta"] as? String,
               let audio = Data(base64Encoded: base64) {
                if Self.isPureSilence(audio) {
                    statsLock.lock()
                    stats.heartbeatsDropped += 1
                    statsLock.unlock()
                } else {
                    statsLock.lock()
                    stats.audioFrames += 1
                    stats.audioBytes += audio.count
                    statsLock.unlock()
                    onTranslatedAudio?(audio)
                }
            }
        case "session.input_transcript.delta":
            if let delta = object["delta"] as? String {
                statsLock.lock()
                stats.sourceDeltas += 1
                stats.sourceChars += delta.count
                statsLock.unlock()
                onSourceTranscriptDelta?(delta)
            }
        case "session.output_transcript.delta":
            if let delta = object["delta"] as? String {
                statsLock.lock()
                stats.translationDeltas += 1
                stats.translationChars += delta.count
                statsLock.unlock()
                onTranslatedTranscriptDelta?(delta)
            }
        case "session.created", "session.updated":
            Log.info("[\(label)] \(type)")
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

    // MARK: - Keepalive

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                guard let self, self.state == .open else { return }
                // The server sends events continuously while a session is
                // healthy (heartbeat audio frames every ~200 ms). A long
                // event gap on an "open" socket means it's half-dead —
                // receive() can hang for minutes without erroring, and a
                // lost pong never invokes the sendPing handler either.
                self.statsLock.lock()
                let eventGap = Date().timeIntervalSince(self.lastServerEventAt)
                self.statsLock.unlock()
                if eventGap > 75 {
                    self.failConnection("no server events for \(Int(eventGap))s — connection presumed dead")
                    return
                }
                self.pingTicks += 1
                if self.pingTicks % 3 == 0 { self.logSummary(context: "periodic") }
                self.task?.sendPing { [weak self] error in
                    if let error {
                        self?.failConnection("ping failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// One-line traffic summary, logged every ~60 s while open and once on
    /// close. Reads as: what we sent vs. what each server stream returned.
    private func logSummary(context: String) {
        statsLock.lock()
        let s = stats
        statsLock.unlock()
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
        Log.info("[\(label)] stats (\(context)): \(line)")
        // ~10 s of sent audio is enough to expect both streams; call out the
        // two symptom signatures explicitly.
        guard s.audioChunksSent > 50 else { return }
        if s.sourceDeltas == 0, s.translationDeltas + s.audioFrames > 0 {
            Log.warn("[\(label)] translation flowing but NO source-transcript deltas — Chinese text will be missing; check session.updated ack / transcription config")
        }
        if s.audioFrames == 0, s.sourceDeltas > 0 {
            Log.warn("[\(label)] source transcript flowing but NO translated audio frames — playback will be silent for this lane")
        }
    }

    private func stopPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }
}

extension RealtimeTranslationClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let latency = connectStartedAt.map { String(format: " (%.1fs)", Date().timeIntervalSince($0)) } ?? ""
        Log.info("[\(label)] WS open\(latency)")
        statsLock.lock()
        lastServerEventAt = Date()
        statsLock.unlock()
        state = .open
        sendJSON(config.sessionUpdateEvent())
        flushPendingAudio()
        startPing()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
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
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        if !intentionallyClosed {
            Log.warn("[\(label)] WS closed (\(closeCode.rawValue)) \(reasonText ?? "")")
        }
        stopPing()
        state = .closed(reasonText)
    }
}
