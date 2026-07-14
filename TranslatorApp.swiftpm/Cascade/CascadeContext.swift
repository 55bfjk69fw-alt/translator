import Foundation
import AVFoundation

/// Cross-lane pieces of one cascade conversation
/// (docs/CASCADE-PIPELINE.md §3): the AnalyzerPool, the shared
/// per-language-pair translator, and the readiness check every lane
/// engine awaits before opening utterances. Created at Start when the
/// cascade pipeline is selected; torn down at Stop (the ONLY place pool
/// slots are ever finished).
final class CascadeContext {

    struct Readiness {
        let poolSize: Int
        let analyzerFormat: AVAudioFormat?
        let translationInstalled: Bool
        /// nil = ready; otherwise the user-facing reason the cascade
        /// cannot run (drives the lane .failed state and the banner
        /// pointing at the setup card).
        var failureText: String? {
            if poolSize == 0 || analyzerFormat == nil {
                return "Speech recognition model unavailable — download it in Settings → Translation pipeline."
            }
            if !translationInstalled {
                return "Translation pack not installed — download it in Settings → Translation pipeline."
            }
            return nil
        }
    }

    let pool = AnalyzerPool()
    let translator: AppleTranslator
    let sourceLocale: Locale
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language

    private let readinessTask: Task<Readiness, Never>

    init(sourceLanguage: String, targetLanguage: String, laneCap: Int) {
        let source = Locale.Language(identifier: sourceLanguage)
        let target = Locale.Language(identifier: targetLanguage)
        self.sourceLanguage = source
        self.targetLanguage = target
        self.sourceLocale = Locale(identifier: sourceLanguage)
        self.translator = AppleTranslator(source: source, target: target)
        let pool = self.pool
        let locale = self.sourceLocale
        // Discovery starts immediately; lanes await ready() before their
        // first acquire, so Start stays synchronous and readiness resolves
        // within the .starting window (sub-second when assets are
        // installed).
        self.readinessTask = Task {
            async let installed = AppleTranslator.isAvailable(source: source, target: target)
            let size = await pool.build(locale: locale, cap: laneCap)
            let format = await pool.analyzerFormat
            return Readiness(
                poolSize: size,
                analyzerFormat: format,
                translationInstalled: await installed
            )
        }
    }

    /// Awaitable, idempotent readiness (memoized by the task).
    func ready() async -> Readiness {
        await readinessTask.value
    }

    /// Stop-only teardown: finishes every pool slot (terminal) and ends
    /// the translator's worker. Lane engines are closed first by AppModel,
    /// so nothing submits after this.
    func teardown() {
        translator.cancelAll()
        Task { [pool] in
            await pool.teardown()
        }
    }
}
