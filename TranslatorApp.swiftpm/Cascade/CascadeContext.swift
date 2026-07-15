import Foundation
import AVFoundation

/// Cross-lane pieces of one cascade conversation
/// (docs/CASCADE-PIPELINE.md §3, §14): the AnalyzerPool, the translation
/// stage's provider-defined translator construction (§5.2 cardinality:
/// Apple shared per pair, OpenAI per lane), the global OpenAI health
/// latch, and the readiness check every lane engine awaits before
/// opening utterances. Created at Start when the cascade pipeline is
/// selected; torn down at Stop (the ONLY place pool slots are ever
/// finished).
final class CascadeContext {

    /// The translation stage's provider, latched at Start.
    enum TranslationProvider {
        case apple
        case openAI(apiKey: String, model: String)
    }

    /// The STT stage's provider, latched at Start (§5.2 cardinality is a
    /// non-issue here: both providers are pool-shaped behind STTPool).
    enum STTProvider {
        case apple
        /// Alibaba Bailian fun-asr-realtime (docs/DATONG-STT.md).
        case funASR(apiKey: String, endpoint: URL)
    }

    struct Readiness {
        let poolSize: Int
        let analyzerFormat: AVAudioFormat?
        let translationInstalled: Bool
        /// OpenAI MT selected: the Apple pack is only the per-job
        /// FALLBACK, so a missing pack must not fail Start (the setup
        /// card shows it in fallback-status form instead).
        let cloudTranslation: Bool
        /// Cloud STT selected: a zero-size pool means the key/network
        /// failed the Start probe, not a missing on-device model.
        let cloudSTT: Bool
        /// nil = ready; otherwise the user-facing reason the cascade
        /// cannot run (drives the lane .failed state and the banner
        /// pointing at the setup card).
        var failureText: String? {
            if poolSize == 0 || analyzerFormat == nil {
                return cloudSTT
                    ? "Fun-ASR unreachable — check the DashScope API key, region, and network in Settings → Translation pipeline."
                    : "Speech recognition model unavailable — download it in Settings → Translation pipeline."
            }
            if !translationInstalled && !cloudTranslation {
                return "Translation pack not installed — download it in Settings → Translation pipeline."
            }
            return nil
        }
    }

    let pool: any STTPool
    /// Diagnostics label for the STT stage ("apple" / "fun-asr-realtime").
    let sttProviderLabel: String
    /// How long a lane waits for the close's final result before settling
    /// with volatile text: Apple's finish flushes locally (probe-proven
    /// ~0.1 s), a cloud final needs a network round trip plus server
    /// finalize — the same 1.2 s would routinely lose cloud finals to the
    /// settle timer. Latched here so the engine stays provider-blind.
    let sttFinalizeGrace: TimeInterval
    let sourceLocale: Locale
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language
    /// Raw BCP-47 target code, latched at Start — per-lane voices must be
    /// resolved against THIS, not a live AppSettings read, or a
    /// mid-conversation language change plus a lane re-enable yields a
    /// voice in the new language speaking the old one's text.
    let targetLanguageCode: String
    /// True when the source language writes in Han script. The lanes'
    /// script gate (docs/ENGLISH-SUPPRESSION.md §4.1) keys on this: a
    /// predominantly-Latin final on a Han-script lane means the speech
    /// was never the source language. Meaningless — and wrong to apply —
    /// for Latin-script sources, where every legitimate final is Latin.
    let sourceUsesHanScript: Bool
    /// Diagnostics label for the translation stage ("apple" /
    /// "openai <model>").
    let translationProviderLabel: String
    /// Non-nil iff the OpenAI translation provider is selected; AppModel
    /// wires onNotice/onCostDelta at Start (the latch banner travels a
    /// context-level path, not a lane's).
    let translationHealth: OpenAITranslationHealth?

    private let translationProvider: TranslationProvider
    /// Prompt/request config, built once (nil for Apple-primary).
    private let openAIRequest: OpenAITranslationRequest?

    /// Guards the lazily-created shared Apple translator (primary OR
    /// fallback) and the per-lane cloud translator registry — created
    /// from audioQueue at Start/lane re-enable, cancelled from main at
    /// Stop.
    private let translatorLock = NSLock()
    private var sharedApple: AppleTranslator?
    private var cloudTranslators: [OpenAIChatTranslator] = []
    /// Once torn down, no NEW translator may be created (a lazily-built
    /// fallback after Stop would leak its worker task forever).
    private var translatorsTornDown = false

    private let readinessTask: Task<Readiness, Never>

    init(sourceLanguage: String, targetLanguage: String, laneCap: Int,
         stt: STTProvider,
         /// Dollar sink for cloud STT billing (CostMeter, thread-safe).
         /// Wired at construction so no billed task can precede it;
         /// ignored by the Apple provider, which never bills.
         sttCostSink: (@Sendable (Double) -> Void)? = nil,
         translation: TranslationProvider,
         awaitingPriorTeardown priorTeardown: Task<Void, Never>?) {
        let source = Locale.Language(identifier: sourceLanguage)
        let target = Locale.Language(identifier: targetLanguage)
        self.sourceLanguage = source
        self.targetLanguage = target
        self.targetLanguageCode = targetLanguage
        self.sourceLocale = Locale(identifier: sourceLanguage)
        // Script from the identifier when explicit (zh-Hans/zh-Hant);
        // fall back on the language code for bare "zh"/"yue".
        let script = source.script?.identifier
        let languageCode = source.languageCode?.identifier
        self.sourceUsesHanScript = script == "Hans" || script == "Hant"
            || languageCode == "zh" || languageCode == "yue"
        self.translationProvider = translation

        let cloudSTT: Bool
        switch stt {
        case .apple:
            self.pool = AnalyzerPool()
            self.sttProviderLabel = "apple"
            self.sttFinalizeGrace = 1.2
            cloudSTT = false
        case .funASR(let apiKey, let endpoint):
            self.pool = FunASRPool(config: FunASRPool.Config(
                apiKey: apiKey,
                endpoint: endpoint,
                model: "fun-asr-realtime",
                languageHint: Self.funASRLanguageHint(for: sourceLanguage),
                costSink: sttCostSink
            ))
            self.sttProviderLabel = "fun-asr-realtime"
            self.sttFinalizeGrace = 2.5
            cloudSTT = true
        }

        let cloudTranslation: Bool
        switch translation {
        case .apple:
            self.translationProviderLabel = "apple"
            self.openAIRequest = nil
            self.translationHealth = nil
            cloudTranslation = false
        case .openAI(let apiKey, let model):
            self.translationProviderLabel = "openai \(model)"
            // English language names — the prompt is English-instructed
            // regardless of device locale.
            let english = Locale(identifier: "en")
            let request = OpenAITranslationRequest(
                apiKey: apiKey,
                model: model,
                sourceName: english.localizedString(forIdentifier: sourceLanguage) ?? sourceLanguage,
                targetName: english.localizedString(forIdentifier: targetLanguage) ?? targetLanguage,
                // Field-observed Mandarin cross-script STT errors; the
                // concrete pairs anchor the sound-reading rule.
                soundAlikeHint: sourceLanguage.hasPrefix("zh")
                    ? "For example, 好 may appear as “how”, and 是 as “xi” or “shi”."
                    : nil
            )
            self.openAIRequest = request
            // The half-open recovery probe: a tiny synthetic request,
            // never a real utterance (§14.1), under the same overall
            // deadline as real jobs.
            self.translationHealth = OpenAITranslationHealth(probe: {
                try await OpenAIChatTranslator.withTimeout(OpenAIChatTranslator.jobTimeoutSeconds) {
                    try await request.stream(text: "OK", context: [], onPartial: { _ in })
                }.cost
            })
            cloudTranslation = true
        }

        let pool = self.pool
        let locale = self.sourceLocale
        // Discovery starts immediately; lanes await ready() before their
        // first acquire, so Start stays synchronous and readiness resolves
        // within the .starting window (sub-second when assets are
        // installed). A quick Stop→Start must first wait out the previous
        // conversation's pool teardown, or the old slots' admission share
        // under-sizes (even zero-sizes) this pool.
        self.readinessTask = Task {
            if let priorTeardown { await priorTeardown.value }
            async let installed = AppleTranslator.isAvailable(source: source, target: target)
            let size = await pool.build(locale: locale, cap: laneCap)
            let format = await pool.analyzerFormat
            return Readiness(
                poolSize: size,
                analyzerFormat: format,
                translationInstalled: await installed,
                cloudTranslation: cloudTranslation,
                cloudSTT: cloudSTT
            )
        }
    }

    /// Two-letter hint for fun-asr-realtime's language_hints (supported
    /// codes from the API doc, 2026-07-15); nil = model auto-detects.
    /// Dialects (晋语 et al.) are detected within "zh" — no dialect
    /// parameter exists. NOTE: a vendor-doc snapshot, most of it
    /// unexercisable today (the source picker only offers Apple-STT ∩
    /// translation languages) and none of it validated against the live
    /// model beyond zh.
    private static let funASRHintCodes: Set<String> = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "tl", "hi", "ar",
        "fr", "de", "es", "pt", "ru", "it", "nl", "sv", "da", "fi", "no",
        "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk"
    ]

    private static func funASRLanguageHint(for sourceLanguage: String) -> String? {
        guard let code = Locale.Language(identifier: sourceLanguage).languageCode?.identifier,
              funASRHintCodes.contains(code) else { return nil }
        return code
    }

    /// Awaitable, idempotent readiness (memoized by the task).
    func ready() async -> Readiness {
        await readinessTask.value
    }

    /// The lane's translator, provider-defined cardinality (§5.2): the
    /// shared per-pair Apple session, or a fresh per-lane OpenAI
    /// translator registered for Stop-time cancellation. Called from
    /// audioQueue (Start's eager open, mid-conversation re-enable).
    func makeTranslator(lane: Int) -> any Translator {
        switch translationProvider {
        case .apple:
            // Never nil here: engines (and their translators) are always
            // created before Stop's teardown; the fallback construction
            // is defensive only.
            return sharedAppleTranslator()
                ?? AppleTranslator(source: sourceLanguage, target: targetLanguage)
        case .openAI:
            // openAIRequest/translationHealth are always non-nil here
            // (both are built with the .openAI case in init).
            let translator = OpenAIChatTranslator(
                lane: lane,
                request: openAIRequest!,
                health: translationHealth!,
                // nil after teardown (an in-flight job's timeout racing
                // Stop) — the job fails as cancelled and its closed
                // engine drops the result.
                fallback: { [weak self] in self?.sharedAppleTranslator() }
            )
            translatorLock.lock()
            cloudTranslators.append(translator)
            translatorLock.unlock()
            return translator
        }
    }

    /// The shared Apple session for the pair — primary translator, or
    /// the OpenAI path's lazily-created per-job fallback ("created
    /// lazily once", §14.1). nil once torn down.
    private func sharedAppleTranslator() -> AppleTranslator? {
        translatorLock.lock()
        defer { translatorLock.unlock() }
        guard !translatorsTornDown else { return nil }
        if let existing = sharedApple { return existing }
        let created = AppleTranslator(source: sourceLanguage, target: targetLanguage)
        sharedApple = created
        return created
    }

    /// Stop-only teardown: finishes every pool slot (terminal), ends the
    /// translators' workers, and stops the recovery probe. Lane engines
    /// are closed first by AppModel, so nothing submits after this.
    /// Returns the task the NEXT conversation's context must await before
    /// building its pool.
    @discardableResult
    func teardown() -> Task<Void, Never> {
        translationHealth?.teardown()
        translatorLock.lock()
        translatorsTornDown = true
        let apple = sharedApple
        let cloud = cloudTranslators
        translatorLock.unlock()
        apple?.cancelAll()
        for translator in cloud { translator.cancelAll() }
        return Task { [pool] in
            await pool.teardown()
        }
    }
}
