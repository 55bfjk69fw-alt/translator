import Foundation

// Stage-provider protocols for the cascade pipeline
// (docs/CASCADE-PIPELINE.md §5.2): the seam future cloud providers
// (OpenAI, DeepL, ElevenLabs — CP4) implement so they drop in next to
// the Apple ones without touching CascadeLaneEngine. The STT stage has
// no protocol yet on purpose: the Apple implementation is pool-shaped
// (AnalyzerPool serves lanes per utterance), and the per-lane streaming
// STT protocol gets extracted when the first per-lane cloud STT provider
// arrives, rather than guessed now.

/// Text-in/text-out translation. Implementations serialize internally;
/// callers may invoke from any queue/task.
protocol Translator: AnyObject {
    /// `job` correlates streaming deltas (onDelta) with the awaited
    /// result. Single-shot providers (Apple, DeepL) never call onDelta.
    func translate(_ text: String, job: UUID) async throws -> String
    var onDelta: ((UUID, String) -> Void)? { get set }
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
