import Foundation
import Translation

/// Translator backed by the headless iOS 26 TranslationSession
/// (docs/CASCADE-PIPELINE.md §6.2). One instance per language pair per
/// conversation, shared by all lanes.
///
/// All translate calls funnel through ONE long-lived task consuming a job
/// stream — no documented concurrent-call support exists, the measured
/// per-sentence cost is small (p50 62 ms), and the session's actor
/// isolation is undocumented, so the session never leaves that task.
final class AppleTranslator: Translator {

    private struct Job {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private let jobs: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>

    /// Callers must have verified availability first (§8.1 setup card /
    /// the Start preflight): a pack-less session throws
    /// TranslationError.notInstalled at translate time, which surfaces
    /// per-job.
    init(source: Locale.Language, target: Locale.Language) {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        self.jobs = continuation
        self.worker = Task {
            let session = TranslationSession(installedSource: source, target: target)
            for await job in stream {
                do {
                    let response = try await session.translate(job.text)
                    job.continuation.resume(returning: response.targetText)
                } catch {
                    job.continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Apple's session is single-shot per string — no streaming deltas.
    var onDelta: ((UUID, String) -> Void)?
    /// On-device translation is free — never fires.
    var onCostDelta: ((Double) -> Void)?

    /// `context` is ignored: the headless session translates one string
    /// at a time with no conversation awareness (the reason the OpenAI
    /// provider exists, §14.1).
    func translate(_ text: String, context: [TranslationContextPair], job: UUID) async throws -> TranslationResult {
        let translated: String = try await withCheckedThrowingContinuation { continuation in
            // A yield racing cancelAll() lands on a finished stream and
            // would leak the continuation (hanging its lane's MT stage
            // forever) — fail it instead.
            let result = jobs.yield(Job(text: text, continuation: continuation))
            if case .terminated = result {
                continuation.resume(throwing: CancellationError())
            }
        }
        return TranslationResult(text: translated, viaFallback: false)
    }

    /// Ends the worker; queued jobs already yielded still complete (the
    /// stream drains), new ones would hang — callers stop submitting
    /// before calling this (Stop tears lanes down first).
    func cancelAll() {
        jobs.finish()
    }

    /// True when the pair's packs are installed (the only state a
    /// headless session can use).
    static func isAvailable(source: Locale.Language, target: Locale.Language) async -> Bool {
        let status = await LanguageAvailability().status(from: source, to: target)
        if case .installed = status { return true }
        return false
    }
}
