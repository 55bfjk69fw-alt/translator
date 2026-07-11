import Foundation

/// Minimal client for OpenAI `POST /v1/chat/completions` with structured
/// output — the reply prompter's only network dependency. One request, one
/// strict-JSON-schema response, no streaming. Payloads are dictionaries
/// (not Codable) for the same reason as SessionConfig: easy to tweak
/// on-device from logged evidence.
struct ChatCompletionClient {

    struct Usage {
        let promptTokens: Int
        let completionTokens: Int
    }

    struct Response {
        /// The parsed JSON object the model returned as message content.
        let content: [String: Any]
        let usage: Usage?
    }

    enum ClientError: LocalizedError {
        case badStatus(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                return "HTTP \(code): \(body)"
            case .malformedResponse(let detail):
                return "Malformed response: \(detail)"
            }
        }
    }

    let apiKey: String
    let model: String
    /// From Settings (AppSettings.assistEndpoint) — relay/proxy users need
    /// this reroutable just like the realtime endpoint template.
    var endpoint: URL = AppSettings.assistEndpoint

    /// No token cap on purpose: the strict schema bounds output size, and
    /// the cap parameter is named differently across model generations.
    func complete(
        system: String,
        user: String,
        schemaName: String,
        schema: [String: Any]
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        // Reasoning models default to slow multi-second thinking — this is
        // a latency-sensitive JSON task, so pin the FLOOR effort per family:
        // gpt-5.1+ accept "none" (behaves like a non-reasoning model), the
        // original gpt-5 family accepts "minimal", o-series bottoms out at
        // "low". The gpt-5-chat-* variants are non-reasoning and reject the
        // parameter entirely. "verbosity: low" additionally trims output
        // tokens on the gpt-5 family (codex/chat variants reject it, but
        // those are filtered out of the model picker).
        if model.hasPrefix("gpt-5"), !model.contains("chat") {
            payload["reasoning_effort"] = model.hasPrefix("gpt-5.") ? "none" : "minimal"
            payload["verbosity"] = "low"
        } else if model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            payload["reasoning_effort"] = "low"
        }
        // Paid fast lane: ~2x token price for faster, more consistent
        // time-to-first-token (docs/REPLY-FLOW.md cost note).
        if AppSettings.priorityProcessing {
            payload["service_tier"] = "priority"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw ClientError.badStatus(http.statusCode, body)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw ClientError.malformedResponse("missing choices/message")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw ClientError.malformedResponse("model refusal: \(refusal)")
        }
        guard let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            throw ClientError.malformedResponse("content is not a JSON object")
        }
        var usage: Usage?
        if let raw = root["usage"] as? [String: Any] {
            usage = Usage(
                promptTokens: raw["prompt_tokens"] as? Int ?? 0,
                completionTokens: raw["completion_tokens"] as? Int ?? 0
            )
        }
        return Response(content: object, usage: usage)
    }

    /// Chat-capable model ids available to this API key, for the Settings
    /// picker. Derived from the configured chat endpoint so relay users
    /// list through their relay too.
    static func listModels(apiKey: String) async throws -> [String] {
        let chat = AppSettings.assistEndpoint.absoluteString
        let suffix = "/chat/completions"
        let modelsURLString = chat.hasSuffix(suffix)
            ? String(chat.dropLast(suffix.count)) + "/models"
            : "https://api.openai.com/v1/models"
        guard let url = URL(string: modelsURLString) else {
            throw ClientError.malformedResponse("bad models URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClientError.badStatus(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw ClientError.malformedResponse("missing data array")
        }
        // Text-chat models only: the account list is full of audio/image/
        // embedding/realtime variants that would 400 on chat completions.
        let excluded = ["realtime", "audio", "tts", "transcribe", "whisper",
                        "embedding", "image", "dall-e", "moderation", "search",
                        "computer-use", "codex", "instruct"]
        let ids = list.compactMap { $0["id"] as? String }.filter { id in
            (id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4"))
                && !excluded.contains(where: { id.contains($0) })
        }
        // Descending so the newest families list first.
        return Array(Set(ids)).sorted(by: >)
    }
}
