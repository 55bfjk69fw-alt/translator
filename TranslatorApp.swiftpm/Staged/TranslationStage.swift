import Foundation

/// One streamed piece of a translation: text deltas while the model writes,
/// plus at most one usage-based cost estimate at the end.
enum TranslationChunk {
    case delta(String)
    case usage(costDollars: Double)
}

/// A finished (source, translation) pair carried as rolling context so the
/// translator keeps pronouns/terminology consistent across utterances.
struct TranslationContextPair {
    let source: String
    let translation: String
}

/// Translation stage of the staged pipeline: one finalized utterance in,
/// streamed translation out. Implementations: OpenAI text (network,
/// quality-first default), Apple Translation (on-device), Apple
/// Intelligence (on-device, experimental).
protocol UtteranceTranslator: AnyObject {
    func translate(_ text: String,
                   from sourceLanguage: String,
                   to targetLanguage: String,
                   context: [TranslationContextPair]) -> AsyncThrowingStream<TranslationChunk, Error>
}

/// Placeholder for a provider that can't run at all (e.g. Apple
/// Intelligence unavailable and no OpenAI key to fall back to). Fails every
/// utterance with the reason so the lane degrades to source-text-only
/// instead of silently dropping speech.
final class UnavailableTranslator: UtteranceTranslator {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func translate(_ text: String, from sourceLanguage: String, to targetLanguage: String,
                   context: [TranslationContextPair]) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "UnavailableTranslator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: reason
            ]))
        }
    }
}

/// OpenAI text translation over streaming chat completions. The staged
/// pipeline's default: translation quality is the one thing the app won't
/// compromise on, and a frontier text model with utterance context beats
/// the realtime speech model on fidelity (and on Mandarin/English
/// code-switching, which gpt-realtime-translate is known to skip).
final class OpenAITextTranslator: UtteranceTranslator {

    static let defaultEndpoint = "https://api.openai.com/v1/chat/completions"

    private let apiKey: String
    private let model: String
    private let endpoint: String

    /// Dollars per 1M (input, output) tokens by model-name prefix, longest
    /// prefix wins. Estimates for the cost meter — kept deliberately small
    /// and conservative; unknown models fall back to flagship pricing.
    private static let pricePerMTokens: [(prefix: String, input: Double, output: Double)] = [
        ("gpt-5.1", 1.25, 10.0),
        ("gpt-5-mini", 0.25, 2.0),
        ("gpt-5-nano", 0.05, 0.40),
        ("gpt-5", 1.25, 10.0),
        ("gpt-4.1-mini", 0.40, 1.60),
        ("gpt-4.1", 2.0, 8.0),
        ("gpt-4o-mini", 0.15, 0.60),
        ("gpt-4o", 2.50, 10.0)
    ]
    private static let fallbackPrice = (input: 2.50, output: 10.0)

    init(apiKey: String, model: String, endpoint: String = OpenAITextTranslator.defaultEndpoint) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    func translate(_ text: String, from sourceLanguage: String, to targetLanguage: String,
                   context: [TranslationContextPair]) -> AsyncThrowingStream<TranslationChunk, Error> {
        let request = makeRequest(text: text, from: sourceLanguage, to: targetLanguage, context: context)
        let model = self.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let request else {
                        throw NSError(domain: "OpenAITextTranslator", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Bad translation endpoint URL"
                        ])
                    }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        // Drain a little of the body: OpenAI errors carry the
                        // reason as JSON and it's the only diagnostic there is.
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw NSError(domain: "OpenAITextTranslator", code: http.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(300))"
                        ])
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let choices = object["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(.delta(content))
                        }
                        // stream_options.include_usage: one final chunk with
                        // empty choices carries the token counts.
                        if let usage = object["usage"] as? [String: Any] {
                            let input = (usage["prompt_tokens"] as? NSNumber)?.doubleValue ?? 0
                            let output = (usage["completion_tokens"] as? NSNumber)?.doubleValue ?? 0
                            let price = Self.price(for: model)
                            let dollars = (input * price.input + output * price.output) / 1_000_000
                            if dollars > 0 { continuation.yield(.usage(costDollars: dollars)) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(text: String, from sourceLanguage: String, to targetLanguage: String,
                             context: [TranslationContextPair]) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        let system = """
        You are a professional simultaneous interpreter. Translate the user's \
        \(Self.languageName(sourceLanguage)) utterances into natural, spoken \
        \(Self.languageName(targetLanguage)). Preserve tone and register. If part of the \
        utterance is already in \(Self.languageName(targetLanguage)), keep it as-is within \
        the translation. Output ONLY the translation — no explanations, no romanization, \
        no quotation marks.
        """
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        // Recent finished pairs give the model pronoun/terminology
        // continuity without growing unboundedly.
        for pair in context.suffix(6) {
            messages.append(["role": "user", "content": pair.source])
            messages.append(["role": "assistant", "content": pair.translation])
        }
        messages.append(["role": "user", "content": text])

        // Kept minimal on purpose: temperature/reasoning knobs vary by model
        // family and an unsupported parameter fails the whole request.
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func price(for model: String) -> (input: Double, output: Double) {
        var best: (prefixLength: Int, input: Double, output: Double)?
        for entry in pricePerMTokens where model.hasPrefix(entry.prefix) {
            if entry.prefix.count > (best?.prefixLength ?? -1) {
                best = (entry.prefix.count, entry.input, entry.output)
            }
        }
        if let best { return (best.input, best.output) }
        return fallbackPrice
    }

    /// Human-readable language name for the prompt; falls back to the code
    /// itself, which models handle fine.
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }
}
