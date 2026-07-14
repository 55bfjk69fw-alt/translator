import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Shared pool of SpeechAnalyzer slots (docs/CASCADE-PIPELINE.md §6.1.1).
///
/// The device admits a limited number of simultaneous analyses (measured:
/// 3 on the target iPad), so analyzers belong to the conversation's
/// CascadeContext, not to lanes. Each slot is a long-lived analyzer +
/// transcriber with a running time cursor; a slot serves ONE lane at a
/// time, so result demux is just "forward to the current owner". Lanes
/// acquire a slot per utterance (FIFO under contention) and release it
/// after finalize-through-the-full-cursor delivers the final result — the
/// invariant that makes owner switches race-free.
///
/// Slot lifecycle rules (design §7 cancellation): lanes NEVER finish a
/// slot (finishing is terminal and would shrink the pool for the rest of
/// the conversation); only teardown() finishes analyzers, at Stop.
actor AnalyzerPool {

    struct ResultEvent {
        let text: String
        let isFinal: Bool
    }

    private final class Slot {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        /// Total seconds of audio fed — the implicit-timeline cursor that
        /// finalize(through:) targets. Carries across acquisitions.
        var cursorSeconds: Double = 0
        var owner: (@Sendable (ResultEvent) -> Void)?
        var harvest: Task<Void, Never>?

        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber,
             continuation: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.continuation = continuation
        }
    }

    private var slots: [Slot] = []
    private var freeSlots: [Int] = []
    /// FIFO waiters; resumed with a slot index, or nil at teardown.
    private var waiters: [CheckedContinuation<Int?, Never>] = []
    private(set) var analyzerFormat: AVAudioFormat?
    private(set) var poolSize = 0
    private var tornDown = false

    // MARK: - Discovery (Start)

    /// Create-and-start identical slots one at a time up to `cap`,
    /// stopping at the admission error — matched by throwing at all, with
    /// domain+code logged; equating the observed code 16 with the
    /// documented `insufficientResources` case is unconfirmed, so nothing
    /// pattern-matches a named case (§6.1.1). Returns the pool size.
    func build(locale: Locale, cap: Int) async -> Int {
        guard slots.isEmpty, !tornDown else { return poolSize }
        guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            Log.error("[pool] \(locale.identifier) is not a SpeechTranscriber locale on this device")
            return 0
        }
        for index in 0..<max(1, cap) {
            do {
                let transcriber = SpeechTranscriber(locale: matched, preset: .progressiveTranscription)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                if analyzerFormat == nil {
                    analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                }
                // Pre-warm before starting the stream (the probe's order;
                // measured effect: finalize p50 0.08 → 0.03 s).
                try await analyzer.prepareToAnalyze(in: analyzerFormat)
                let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                try await analyzer.start(inputSequence: stream)
                let slot = Slot(analyzer: analyzer, transcriber: transcriber, continuation: continuation)
                let slotIndex = slots.count
                slots.append(slot)
                freeSlots.append(slotIndex)
                slot.harvest = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            await self?.deliver(
                                slotIndex: slotIndex,
                                event: ResultEvent(text: String(result.text.characters), isFinal: result.isFinal)
                            )
                        }
                    } catch {
                        Log.warn("[pool] slot \(slotIndex) results stream ended with error: \(error.localizedDescription)")
                    }
                }
            } catch {
                let ns = error as NSError
                Log.info("[pool] admission stopped at slot \(index + 1): \(error.localizedDescription) [\(ns.domain) \(ns.code)] — pool size \(index)")
                break
            }
        }
        poolSize = slots.count
        Log.info("[pool] \(poolSize) analyzer slot(s) ready for \(matched.identifier) (format: \(analyzerFormat.map { "\(Int($0.sampleRate)) Hz" } ?? "unknown"))")
        return poolSize
    }

    // MARK: - Acquisition (per utterance)

    /// Returns a slot index bound to `onResult`, suspending FIFO under
    /// contention. nil = pool empty or torn down.
    func acquire(onResult: @escaping @Sendable (ResultEvent) -> Void) async -> Int? {
        guard !tornDown, poolSize > 0 else { return nil }
        if let free = freeSlots.first {
            freeSlots.removeFirst()
            slots[free].owner = onResult
            return free
        }
        let index: Int? = await withCheckedContinuation { waiters.append($0) }
        guard let index, !tornDown else { return nil }
        slots[index].owner = onResult
        return index
    }

    /// Feed converted audio to a held slot; advances its cursor.
    func feed(slotIndex: Int, buffer: AVAudioPCMBuffer) {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let slot = slots[slotIndex]
        slot.continuation.yield(AnalyzerInput(buffer: buffer))
        slot.cursorSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
    }

    /// Force the final result for everything fed so far (the full-cursor
    /// close rule — never `lastSpeechTime`, so no un-finalized volatile
    /// region can remain at release). Does NOT release: the lane engine
    /// waits for the final to arrive on its onResult (bounded by its own
    /// timeout) and then calls release() — the wait lives where the
    /// knowledge is.
    func finalizeCurrent(slotIndex: Int) async {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let slot = slots[slotIndex]
        let cursor = CMTime(seconds: slot.cursorSeconds, preferredTimescale: 48_000)
        do {
            try await slot.analyzer.finalize(through: cursor)
        } catch {
            Log.warn("[pool] finalize(through:) failed on slot \(slotIndex): \(error.localizedDescription)")
        }
    }

    /// Unbind the owner and grant the slot to the next FIFO waiter.
    func release(slotIndex: Int) {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        slots[slotIndex].owner = nil
        if waiters.isEmpty {
            freeSlots.append(slotIndex)
        } else {
            waiters.removeFirst().resume(returning: slotIndex)
        }
    }

    // MARK: - Teardown (Stop only)

    /// Finish every analyzer (terminal), draining in-flight results.
    /// Measured drain is fast (finalize ~0.1 s); the per-slot finish is
    /// awaited directly and the 3 s cap in the design is enforced by the
    /// caller racing this against a timeout if it ever matters.
    func teardown() async {
        guard !tornDown else { return }
        tornDown = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
        for (index, slot) in slots.enumerated() {
            slot.continuation.finish()
            do {
                try await slot.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Log.warn("[pool] slot \(index) finish failed: \(error.localizedDescription)")
                slot.harvest?.cancel()
            }
        }
        slots.removeAll()
        freeSlots.removeAll()
        poolSize = 0
        Log.info("[pool] torn down")
    }

    // MARK: - Result routing

    private func deliver(slotIndex: Int, event: ResultEvent) {
        guard slots.indices.contains(slotIndex) else { return }
        // No owner = the window between release and the next acquire;
        // stray late results are dropped by design (release only happens
        // after the owner saw its final or timed out waiting).
        slots[slotIndex].owner?(event)
    }
}
