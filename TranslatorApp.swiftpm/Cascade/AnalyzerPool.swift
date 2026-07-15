import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Shared pool of SpeechAnalyzer slots (docs/CASCADE-PIPELINE.md §6.1.1).
///
/// The device admits a limited number of simultaneous analyses (measured:
/// 3 on the target iPad), so analyzers belong to the conversation's
/// CascadeContext, not to lanes. A slot serves ONE utterance for ONE
/// lane, so result demux is just "forward to the current owner": acquire
/// (FIFO under contention) → feed → finishAndRetire, which flushes the
/// final result, retires the slot, and spawns a pre-warmed replacement.
///
/// FIELD REVISION (2026-07-15, supersedes the design's long-lived-slot
/// model): finalize(through:) — the mechanism §6.1.1 was built on — hangs
/// indefinitely on live streams on-device in every form tried, while
/// finish-at-utterance-end flushes finals in ~0.1 s (probe-proven). So
/// slots are per-utterance, and every analyzer await is BOUNDED so a hung
/// OS call can never wedge a lane's command worker.
actor AnalyzerPool: STTPool {

    /// The pool's original result shape, now the seam-wide one (STTPool).
    typealias ResultEvent = STTResultEvent

    private final class Slot {
        var analyzer: SpeechAnalyzer?
        var transcriber: SpeechTranscriber?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        /// Total seconds of audio fed (diagnostics only — finalization
        /// is finish-at-utterance-end, no cursor targeting).
        var cursorSeconds: Double = 0
        var owner: (@Sendable (ResultEvent) -> Void)?
        var harvest: Task<Void, Never>?
        /// Retired: finished (or broken) and awaiting only deallocation;
        /// never granted again. Slots are PER-UTTERANCE — field evidence
        /// (2026-07-15): finalize(through:) hangs indefinitely on live
        /// streams in every form, while finish-at-utterance-end flushes
        /// finals in ~0.1 s (probe-proven), so each slot serves one
        /// utterance and is then finished and replaced.
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
    /// Replacements currently in flight (spawned by retire, resolved by
    /// replaceRetiredSlot). Zero live slots is only "transient" while
    /// this is nonzero — the acquire guard keys on it.
    private var pendingReplacements = 0
    private var slowRecoveryRunning = false

    private var liveCount: Int {
        slots.indices.filter { !slots[$0].retired }.count
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
            // A Stop can land during the awaits above; a slot appended to
            // a torn-down pool would hold its admission share into the
            // NEXT conversation's build.
            guard !tornDown else {
                Task { await analyzer.cancelAndFinishNow() }
                return false
            }
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
        guard !tornDown else { return nil }
        // Zero live slots is TRANSIENT with per-utterance slots (three
        // simultaneous closes retire three slots at once; replacements
        // are 0.25-0.75 s out) — wait while replacements are in flight.
        // With none pending AND none live the pool is genuinely dead:
        // fail fast so lanes surface .failed instead of waiting forever
        // behind green dots (the slow-recovery loop below revives the
        // pool if the OS relents, and poolSize > 0 re-opens this guard).
        guard poolSize > 0 || pendingReplacements > 0 else { return nil }
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
        guard !slot.retired, let continuation = slot.continuation else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
        slot.cursorSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
    }

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
        guard !slots[slotIndex].retired, let continuation = slots[slotIndex].continuation else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
        slots[slotIndex].cursorSeconds += seconds
    }

    /// End-of-utterance finish: the ONLY finalization path field-proven
    /// to flush finals (probe: 0.03–0.08 s; finalize(through:) hung
    /// indefinitely on live streams in every form across four field
    /// runs). The final result arrives through the harvest DURING this
    /// call; the slot is then retired and a replacement spawned. Bounded:
    /// nothing may wedge a lane's command worker.
    func finishAndRetire(slotIndex: Int) async {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let slot = slots[slotIndex]
        guard !slot.retired, let analyzer = slot.analyzer else { return }
        slot.continuation?.finish()
        let finished = await Self.awaitBounded(seconds: 2.5) {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Log.warn("[pool] finish threw on slot \(slotIndex): \(error.localizedDescription)")
            }
        }
        if !finished {
            Log.warn("[pool] finish timed out on slot \(slotIndex) — cancelling")
            _ = await Self.awaitBounded(seconds: 2) {
                await analyzer.cancelAndFinishNow()
            }
        }
        retire(slotIndex: slotIndex)
    }

    /// Return a slot that never received audio (a grant that arrived
    /// after its utterance settled): virgin slots go back to the free
    /// list or straight to the next waiter.
    func release(slotIndex: Int) {
        guard slots.indices.contains(slotIndex), !tornDown,
              !slots[slotIndex].retired else { return }
        slots[slotIndex].owner = nil
        if waiters.isEmpty {
            freeSlots.append(slotIndex)
        } else {
            waiters.removeFirst().resume(returning: slotIndex)
        }
    }

    /// Broken slot (results stream error): cancel its analyzer (bounded —
    /// the documented escape hatch, which also frees its admission share)
    /// and retire it.
    private func markDead(slotIndex: Int) async {
        guard slots.indices.contains(slotIndex), !slots[slotIndex].retired,
              let analyzer = slots[slotIndex].analyzer else { return }
        _ = await Self.awaitBounded(seconds: 2) {
            await analyzer.cancelAndFinishNow()
        }
        retire(slotIndex: slotIndex)
    }

    /// Drop every reference the slot holds (the analyzer must deallocate
    /// for its admission share to free) and spawn a replacement.
    /// Zero live slots is TRANSIENT (a replacement is coming), so waiters
    /// are NOT failed here — an utterance that can't get a slot settles
    /// empty via its own timeout and the lane recovers on the next grant.
    private func retire(slotIndex: Int) {
        guard slots.indices.contains(slotIndex), !slots[slotIndex].retired else { return }
        let slot = slots[slotIndex]
        slot.retired = true
        slot.owner = nil
        slot.harvest?.cancel()
        slot.harvest = nil
        slot.continuation?.finish()
        slot.continuation = nil
        slot.analyzer = nil
        slot.transcriber = nil
        freeSlots.removeAll { $0 == slotIndex }
        poolSize = liveCount
        if !tornDown {
            pendingReplacements += 1
            Task { [weak self] in await self?.replaceRetiredSlot() }
        }
    }

    /// Replacement with backoff: the finished analyzer's admission share
    /// frees ASYNCHRONOUSLY after deallocation — an instant retry was
    /// observed denied 20 ms after teardown, so patience beats speed.
    private func replaceRetiredSlot() async {
        defer { pendingReplacements = max(0, pendingReplacements - 1) }
        guard !tornDown, let locale = buildLocale else { return }
        for delay in [0.25, 0.75, 2.0, 4.0] {
            guard !tornDown, liveCount < buildCap else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if await makeSlot(locale: locale) {
                Log.info("[pool] replacement slot ready — \(poolSize) live slot(s)")
                return
            }
        }
        Log.warn("[pool] replacement failed after 4 attempts — \(poolSize) live slot(s)")
        // Last replacement exhausted with nothing live: the pool is dead.
        // Fail the waiters NOW (their lanes go .failed with the settings
        // message instead of silently waiting behind green dots) and keep
        // a slow recovery loop so a transient OS refusal (>7 s admission
        // outage) doesn't stay fatal for the whole conversation.
        if liveCount == 0, pendingReplacements <= 1, !tornDown {
            for waiter in waiters { waiter.resume(returning: nil) }
            waiters.removeAll()
            startSlowRecovery(locale: locale)
        }
    }

    /// Perpetual ~10 s retry while the pool is dead; exits on teardown or
    /// the first success (which re-opens the acquire guard via poolSize).
    private func startSlowRecovery(locale: Locale) {
        guard !slowRecoveryRunning, !tornDown else { return }
        slowRecoveryRunning = true
        Log.warn("[pool] pool is empty and replacements exhausted — retrying every 10 s")
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                if await self.slowRecoveryTick(locale: locale) { return }
            }
        }
    }

    /// Returns true when the loop should stop.
    private func slowRecoveryTick(locale: Locale) async -> Bool {
        if tornDown || liveCount > 0 {
            slowRecoveryRunning = false
            return true
        }
        if await makeSlot(locale: locale) {
            Log.info("[pool] pool recovered — \(poolSize) live slot(s)")
            slowRecoveryRunning = false
            return true
        }
        return false
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
            slot.continuation?.finish()
            guard let analyzer = slot.analyzer else { continue }
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
                    await analyzer.cancelAndFinishNow()
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
        // No owner = a retired slot's stragglers or the window around a
        // virgin release — dropped by design (the engine's epoch stamp is
        // the second line of defense).
        slots[slotIndex].owner?(event)
    }
}
