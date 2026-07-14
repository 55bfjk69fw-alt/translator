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
        /// A finalize failed or hung on this slot: an un-finalized region
        /// may survive its release, so it must never be granted again
        /// (its leftover results could be delivered to another lane).
        var suspect = false
        /// Fully retired (markDead ran): idempotency latch.
        var retired = false

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
    /// Saved from build() so retired slots can be replaced like-for-like.
    private var buildLocale: Locale?
    private var buildCap = 0

    private var liveCount: Int {
        slots.indices.filter { !slots[$0].suspect }.count
    }

    /// Resume a continuation exactly once from whichever of two racing
    /// tasks gets there first — the abandonment primitive that keeps a
    /// HUNG provider call (finalize was observed never returning
    /// on-device) from wedging a lane's command worker. A task group
    /// can't do this: it awaits all children before returning.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
        func resume(_ value: Bool) {
            lock.lock()
            let taken = continuation
            continuation = nil
            lock.unlock()
            taken?.resume(returning: value)
        }
    }

    /// Run an operation with a hard wall-clock bound; false = it did not
    /// finish in time (the operation task is abandoned, not cancelled —
    /// it may complete later and its resume is a no-op).
    private static func awaitBounded(seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                await operation()
                once.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(false)
            }
        }
    }

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
        buildLocale = matched
        buildCap = max(1, cap)
        for index in 0..<buildCap {
            if await !makeSlot(locale: matched) {
                Log.info("[pool] admission stopped at slot \(index + 1) — pool size \(index)")
                break
            }
        }
        Log.info("[pool] \(poolSize) analyzer slot(s) ready for \(matched.identifier) (format: \(analyzerFormat.map { "\(Int($0.sampleRate)) Hz" } ?? "unknown"))")
        return poolSize
    }

    /// Create-and-start one slot; used by build() and by retirement
    /// replacement. Serves a pending waiter directly when one exists.
    private func makeSlot(locale: Locale) async -> Bool {
        do {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
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
            slot.harvest = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        await self?.deliver(
                            slotIndex: slotIndex,
                            event: ResultEvent(text: String(result.text.characters), isFinal: result.isFinal)
                        )
                    }
                } catch {
                    // Slot death (§8.2): a dead slot left in the free
                    // list is a black hole that silently eats every Nth
                    // utterance — retire and replace instead. This also
                    // catches a slot that over-counted discovery by
                    // failing on its results stream at birth.
                    Log.warn("[pool] slot \(slotIndex) died (results stream error: \(error.localizedDescription))")
                    await self?.markDead(slotIndex: slotIndex)
                }
            }
            if waiters.isEmpty {
                freeSlots.append(slotIndex)
            } else {
                slots[slotIndex].owner = nil
                waiters.removeFirst().resume(returning: slotIndex)
            }
            poolSize = liveCount
            return true
        } catch {
            let ns = error as NSError
            Log.info("[pool] slot creation failed: \(error.localizedDescription) [\(ns.domain) \(ns.code)]")
            return false
        }
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
    /// Feed zero-filled audio to a held slot: end-of-speech evidence plus
    /// input progress past the finalize boundary, which streaming ASR
    /// needs to flush a finalization (first field test: closes starved of
    /// post-boundary input produced no finals). The pad is finalized with
    /// everything else, so no dangling region survives release.
    func feedSilence(slotIndex: Int, seconds: Double) {
        guard slots.indices.contains(slotIndex), !tornDown,
              let format = analyzerFormat else { return }
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        if let channel = buffer.int16ChannelData {
            memset(channel[0], 0, Int(frames) * MemoryLayout<Int16>.size)
        } else if let channel = buffer.floatChannelData {
            memset(channel[0], 0, Int(frames) * MemoryLayout<Float>.size)
        }
        slots[slotIndex].continuation.yield(AnalyzerInput(buffer: buffer))
        slots[slotIndex].cursorSeconds += seconds
    }

    func finalizeCurrent(slotIndex: Int) async {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let analyzer = slots[slotIndex].analyzer
        // nil = finalize everything fed so far (the first field test's
        // cursor-targeted CMTime produced no finals). BOUNDED: the second
        // field test showed finalize can hang INDEFINITELY, and an
        // unbounded await here wedged the lane's command worker — every
        // subsequent release/acquire queued behind it and the lane went
        // permanently silent (0V/0F). A timed-out finalize quarantines
        // the slot; release retires and replaces it.
        let completed = await Self.awaitBounded(seconds: 2.5) {
            do {
                try await analyzer.finalize(through: nil)
            } catch {
                Log.warn("[pool] finalize threw on slot \(slotIndex): \(error.localizedDescription)")
            }
        }
        if !completed {
            Log.warn("[pool] finalize did not return within 2.5 s on slot \(slotIndex) — quarantining (retired at release, replacement spawned)")
            if slots.indices.contains(slotIndex) { slots[slotIndex].suspect = true }
        }
    }

    /// Unbind the owner and grant the slot to the next FIFO waiter (or
    /// retire it if a failed finalize made it suspect).
    func release(slotIndex: Int) {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        slots[slotIndex].owner = nil
        if slots[slotIndex].suspect {
            markDead(slotIndex: slotIndex)
            return
        }
        if waiters.isEmpty {
            freeSlots.append(slotIndex)
        } else {
            waiters.removeFirst().resume(returning: slotIndex)
        }
    }

    /// Retire a slot: never grant it again, tear its analyzer down with
    /// the documented escape hatch for hung sessions (cancelAndFinishNow
    /// — which also frees its ADMISSION share), and spawn a like-for-like
    /// replacement so the pool heals instead of shrinking. If the pool
    /// momentarily hits zero, fail pending waiters so lanes surface
    /// .failed instead of hanging.
    private func markDead(slotIndex: Int) {
        guard slots.indices.contains(slotIndex), !slots[slotIndex].retired else { return }
        let slot = slots[slotIndex]
        slot.retired = true
        slot.suspect = true
        slot.owner = nil
        slot.harvest?.cancel()
        slot.continuation.finish()
        freeSlots.removeAll { $0 == slotIndex }
        poolSize = liveCount
        Log.warn("[pool] slot \(slotIndex) retired — \(poolSize) live slot(s) remain; spawning replacement")
        if poolSize == 0 {
            for waiter in waiters { waiter.resume(returning: nil) }
            waiters.removeAll()
        }
        let analyzer = slot.analyzer
        Task { [weak self] in
            // Free the retired analyzer's admission share first, bounded
            // (it may be the hung one), then attempt the replacement.
            _ = await Self.awaitBounded(seconds: 3) {
                do {
                    try await analyzer.cancelAndFinishNow()
                } catch {
                    Log.warn("[pool] cancelAndFinishNow failed on retired slot \(slotIndex): \(error.localizedDescription)")
                }
            }
            await self?.replaceRetiredSlot()
        }
    }

    private func replaceRetiredSlot() async {
        guard !tornDown, let locale = buildLocale, liveCount < buildCap else { return }
        if await makeSlot(locale: locale) {
            Log.info("[pool] replacement slot ready — \(poolSize) live slot(s)")
        } else {
            Log.warn("[pool] replacement slot creation failed — pool stays at \(poolSize)")
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
        for (index, slot) in slots.enumerated() where !slot.retired {
            slot.continuation.finish()
            let analyzer = slot.analyzer
            // Bounded like every other analyzer await: a hung slot must
            // not hang teardown — the NEXT conversation's Start awaits
            // this task before building its pool.
            let finished = await Self.awaitBounded(seconds: 3) {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Log.warn("[pool] slot \(index) finish failed: \(error.localizedDescription)")
                }
            }
            if !finished {
                Log.warn("[pool] slot \(index) finish timed out — abandoning")
                _ = await Self.awaitBounded(seconds: 2) {
                    try? await analyzer.cancelAndFinishNow()
                }
            }
            slot.harvest?.cancel()
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
