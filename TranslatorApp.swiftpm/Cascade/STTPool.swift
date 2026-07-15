import Foundation
import AVFoundation

/// One STT result for the slot's current utterance. `text` is the full
/// replacement text of the current sentence/segment (volatile results
/// revise wholesale); `isFinal` marks it immutable. Mirrors the transcript
/// replace-path contract (docs/CASCADE-PIPELINE.md §5.2).
struct STTResultEvent {
    let text: String
    let isFinal: Bool
}

/// The STT stage seam, extracted at the pool-verb altitude the design
/// doc deferred ("the per-lane streaming STT protocol gets extracted when
/// the first per-lane cloud STT provider arrives") — that provider is
/// FunASRPool (docs/DATONG-STT.md), and what CascadeLaneEngine actually
/// consumes is exactly AnalyzerPool's per-utterance verb surface, so the
/// seam lands there rather than at the per-stream shape §5.2 sketched:
/// pool-shaped providers keep the engine's ordered command worker, slot
/// epochs, and settle discipline untouched.
///
/// Contract (all of it inherited from AnalyzerPool's field-proven
/// semantics):
///  - `build` once per conversation (CascadeContext readiness); returns
///    the usable slot count, 0 = stage unavailable (fails Start).
///  - A slot serves ONE utterance for ONE lane: `acquire` (FIFO under
///    contention, nil = torn down/dead) → `feed`/`feedSilence` →
///    `finishAndRetire` (flushes the final; the slot handle is invalid
///    after). `release` returns a slot that never received audio.
///  - Results are delivered through the acquire-time callback, on any
///    thread, DURING calls included (finals arrive inside
///    finishAndRetire). Stragglers after retire are dropped pool-side.
///  - Every method is bounded: a hung provider call must never wedge a
///    lane's command worker.
///  - `analyzerFormat` is the format `feed` expects (the lane engine owns
///    the converter); non-nil once `build` succeeds.
protocol STTPool: Actor {
    var analyzerFormat: AVAudioFormat? { get }
    func build(locale: Locale, cap: Int) async -> Int
    func acquire(onResult: @escaping @Sendable (STTResultEvent) -> Void) async -> Int?
    func feed(slotIndex: Int, buffer: AVAudioPCMBuffer)
    func feedSilence(slotIndex: Int, seconds: Double)
    func finishAndRetire(slotIndex: Int) async
    func release(slotIndex: Int)
    func teardown() async
}
