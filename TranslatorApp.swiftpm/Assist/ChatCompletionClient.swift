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

        let payload: [String: Any] = [
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
}
