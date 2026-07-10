import Foundation
import FoundationModels

/// Translation via the on-device Apple Intelligence model (FoundationModels).
/// Experimental: the system model is small and not tuned for translation —
/// offered for exploration; OpenAI remains the quality default.
///
/// ⚠️ Like SpeechTranscriberStage, this is written against the iOS 26
/// FoundationModels surface (SystemLanguageModel / LanguageModelSession) and
/// must be verified on-device.
@available(iOS 26.0, *)
final class FoundationModelsTranslator: UtteranceTranslator {

    private let instructionsFor: (String, String) -> String = { source, target in
        """
        You are a professional translator. Translate every message you \
        receive from \(source) into natural, spoken \(target). Preserve tone \
        and register. Reply ONLY with the translation — no explanations, no \
        romanization, no quotation marks.
        """
    }

    /// One stateful session: the running transcript gives the model
    /// pronoun/terminology continuity for free. Recreated when the small
    /// (~4k-token) context window overflows.
    private var session: LanguageModelSession?
    private let lock = NSLock()

    /// Human-readable reason the system model can't run right now, or nil
    /// when it's available. Used by Start's pre-flight check.
    static var availabilityProblem: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        }
    }

    /// nil when the device can't run Apple Intelligence (ineligible
    /// hardware, feature disabled, model still downloading) — the caller
    /// falls back or surfaces the reason.
    init?() {
        if let problem = Self.availabilityProblem {
            Log.warn("[translation] Apple Intelligence unavailable: \(problem)")
            return nil
        }
    }

    func translate(_ text: String, from sourceLanguage: String, to targetLanguage: String,
                   context: [TranslationContextPair]) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.respondWithRecovery(
                        to: text, from: sourceLanguage, to: targetLanguage)
                    continuation.yield(.delta(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Single-flight by construction: the lane worker serializes segments,
    /// so the session never sees concurrent requests.
    private func respondWithRecovery(to text: String, from sourceLanguage: String,
                                     to targetLanguage: String) async throws -> String {
        let session = currentSession(from: sourceLanguage, to: targetLanguage)
        do {
            return try await session.respond(to: text).content
        } catch {
            // The model's context window is small; a long conversation
            // overflows it eventually. Start a fresh session (losing the
            // transcript continuity, keeping the instructions) and retry
            // once — for any error, since a stale session is the common
            // failure mode and a retry is cheap on-device.
            Log.warn("[translation] Apple Intelligence respond failed (\(error.localizedDescription)) — fresh session, one retry")
            let fresh = resetSession(from: sourceLanguage, to: targetLanguage)
            return try await fresh.respond(to: text).content
        }
    }

    private func currentSession(from source: String, to target: String) -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let fresh = makeSession(from: source, to: target)
        session = fresh
        return fresh
    }

    private func resetSession(from source: String, to target: String) -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }
        let fresh = makeSession(from: source, to: target)
        session = fresh
        return fresh
    }

    private func makeSession(from source: String, to target: String) -> LanguageModelSession {
        let session = LanguageModelSession(instructions: instructionsFor(
            OpenAITextTranslator.languageName(source),
            OpenAITextTranslator.languageName(target)
        ))
        session.prewarm()
        return session
    }
}
