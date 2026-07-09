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
    private(set) var state: State = .idle {
        didSet {
            // A drop fires both the receive-failure path and didCloseWith;
            // collapse closed->closed so observers see one transition.
            if case .closed = oldValue, case .closed = state { return }
            onStateChange?(state)
        }
    }

    // Callbacks fire on an arbitrary queue; consumers hop to main as needed.
    var onStateChange: ((State) -> Void)?
    var onSourceTranscriptDelta: ((String) -> Void)?
    var onSourceTranscriptDone: ((String?) -> Void)?
    var onTranslatedTranscriptDelta: ((String) -> Void)?
    var onTranslatedTranscriptDone: ((String?) -> Void)?
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
        state = .connecting

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

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

    func close() {
        intentionallyClosed = true
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

    // MARK: - Sending

    /// Append 24 kHz mono PCM16 audio to the session's input buffer.
    func sendAudio(_ pcm16: Data) {
        guard state == .open else { return }
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ]
        sendJSON(event)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error, let self, !self.intentionallyClosed {
                Log.error("[\(self.label)] WS send failed: \(error.localizedDescription)")
            }
        }
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

    // Event-type aliases: first-match wins. Covers both the documented
    // translation-session names (session.*_transcript.*) and the older
    // conversation/response names in case the server uses those.
    private static let sourceDeltaTypes: Set<String> = [
        "session.input_transcript.delta",
        "input_transcript.delta",
        "conversation.item.input_audio_transcription.delta"
    ]
    private static let sourceDoneTypes: Set<String> = [
        "session.input_transcript.done",
        "session.input_transcript.completed",
        "input_transcript.done",
        "conversation.item.input_audio_transcription.completed"
    ]
    private static let translatedDeltaTypes: Set<String> = [
        "session.output_transcript.delta",
        "output_transcript.delta",
        "response.output_audio_transcript.delta",
        "response.audio_transcript.delta"
    ]
    private static let translatedDoneTypes: Set<String> = [
        "session.output_transcript.done",
        "session.output_transcript.completed",
        "output_transcript.done",
        "response.output_audio_transcript.done",
        "response.audio_transcript.done"
    ]
    private static let audioDeltaTypes: Set<String> = [
        "session.output_audio.delta",
        "output_audio.delta",
        "response.output_audio.delta",
        "response.audio.delta"
    ]

    private func handleEventText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            Log.warn("[\(label)] Unparseable WS message (\(text.prefix(500)))")
            return
        }

        if Self.audioDeltaTypes.contains(type) {
            if let base64 = (object["delta"] as? String) ?? (object["audio"] as? String),
               let audio = Data(base64Encoded: base64) {
                onTranslatedAudio?(audio)
            }
            return
        }
        if Self.sourceDeltaTypes.contains(type) {
            if let delta = Self.textPayload(of: object) { onSourceTranscriptDelta?(delta) }
            return
        }
        if Self.sourceDoneTypes.contains(type) {
            onSourceTranscriptDone?(Self.textPayload(of: object))
            return
        }
        if Self.translatedDeltaTypes.contains(type) {
            if let delta = Self.textPayload(of: object) { onTranslatedTranscriptDelta?(delta) }
            return
        }
        if Self.translatedDoneTypes.contains(type) {
            onTranslatedTranscriptDone?(Self.textPayload(of: object))
            return
        }

        switch type {
        case "session.created", "session.updated":
            Log.info("[\(label)] \(type)")
        case "error":
            // Log the complete error payload — this is the primary evidence
            // for correcting the session.update shape or endpoint.
            Log.error("[\(label)] Server error: \(text.prefix(2000))")
        default:
            // Unknown event: log the full payload so the alias tables above
            // can be extended from real evidence.
            Log.info("[\(label)] Unhandled event \(type): \(text.prefix(2000))")
        }
    }

    private static func textPayload(of object: [String: Any]) -> String? {
        (object["delta"] as? String)
            ?? (object["text"] as? String)
            ?? (object["transcript"] as? String)
    }

    // MARK: - Keepalive

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { error in
                    if let error { Log.warn("Ping failed: \(error.localizedDescription)") }
                }
            }
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
        Log.info("[\(label)] WS open")
        state = .open
        sendJSON(config.sessionUpdateEvent())
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
