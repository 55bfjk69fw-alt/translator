import Foundation

// Stage-provider protocols for the cascade pipeline
// (docs/CASCADE-PIPELINE.md §5.2): the seam future cloud providers
// (OpenAI, DeepL, ElevenLabs — CP4) implement so they drop in next to
// the Apple ones without touching CascadeLaneEngine. The STT stage has
// no protocol yet on purpose: the Apple implementation is pool-shaped
// (AnalyzerPool serves lanes per utterance), and the per-lane streaming
// STT protocol gets extracted when the first per-lane cloud STT provider
// arrives, rather than guessed now.

/// One finalized source→translation exchange from the shared cross-lane
/// context window (docs/CASCADE-PIPELINE.md §14.1). Built by AppModel on
/// main (speaker names are main-confined) and PUSHED into engines — a
/// lane engine's queue never blocks on main.
struct TranslationContextPair {
    let speaker: String
    let source: String
    let translation: String
}

/// What a translate job resolved to. `viaFallback` marks a cloud
/// provider's job that was served by its on-device fallback — the engine
/// counts it in Diagnostics and excludes the pair from the shared
/// context window (fallback output would teach the literal style the
/// cloud provider exists to avoid).
struct TranslationResult {
    let text: String
    let viaFallback: Bool
}

/// Text-in/text-out translation. Implementations serialize internally;
/// callers may invoke from any queue/task. Each job resolves EXACTLY
/// once (the single-resolution invariant, §14.1): a timeout-triggered
/// fallback and a late cloud success must never both surface.
protocol Translator: AnyObject {
    /// `job` correlates streaming deltas (onDelta) with the awaited
    /// result. `context` is the pushed cross-lane window; on-device
    /// providers ignore it.
    func translate(_ text: String, context: [TranslationContextPair], job: UUID) async throws -> TranslationResult
    /// Streaming translation-so-far (ACCUMULATED text, not increments —
    /// the consumer replaces bubble text wholesale). Single-shot
    /// providers (Apple) never call it. Stops firing once the job
    /// resolves.
    var onDelta: ((UUID, String) -> Void)? { get set }
    /// Monotonic dollar increments from token usage. On-device providers
    /// never fire it. Wiring is per-instance: only per-lane providers may
    /// fire this (the shared Apple instance has its closures clobbered by
    /// whichever lane wired last — harmless only while it never calls).
    var onCostDelta: ((Double) -> Void)? { get set }
    /// Ends the worker; in-flight jobs complete or fail, later submits
    /// fail fast. Stop-time only.
    func cancelAll()
}

/// One utterance-at-a-time speech synthesis. The LANE ENGINE owns the
/// queue and backpressure and submits at most one job at a time
/// (submitting the next on onFinished); implementations just render.
/// Audio arrives as 24 kHz mono PCM16 LE chunks — the playback seam.
protocol SpeechSynth: AnyObject {
    func synthesize(text: String, job: UUID)
    /// Stop/close only (no per-job cancel by design — drops happen in the
    /// engine's queue before submission).
    func cancelAll()
    var onAudio: ((UUID, Data) -> Void)? { get set }
    var onFinished: ((UUID, String?) -> Void)? { get set }
}
