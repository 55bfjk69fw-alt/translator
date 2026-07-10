import Foundation

/// Staged pipeline session for one lane: on-device STT → utterance
/// segmentation → translation → TTS, behind the same TranslationLaneSession
/// surface as the realtime WebSocket client.
///
/// Latency/quality split: the live (volatile) source transcript streams
/// into the UI immediately via onSegmentSource, while translation — the
/// quality-critical stage — runs on finalized utterances with rolling
/// conversational context.
///
/// Threading: sendAudio only yields into a bounded AsyncStream (safe from
/// AppModel's audio queue). All pipeline state is confined to the tasks
/// that own it: the STT feed task, the results/segmentation path (a small
/// actor, because a ticker and the results loop both touch it), and one
/// worker task that serializes translation+TTS per segment IN ORDER — so
/// segment N's audio is fully handed to the consumer before N+1's, matching
/// the player nodes' strictly-ordered playback.
@available(iOS 26.0, *)
final class StagedTranslationClient: TranslationLaneSession {

    let label: String

    var onStateChange: ((LaneSessionState) -> Void)?
    var onSourceTranscriptDelta: ((String) -> Void)?        // unused (realtime style)
    var onTranslatedTranscriptDelta: ((String) -> Void)?    // unused (realtime style)
    var onTranslatedAudio: ((Data) -> Void)?                // unused (audio is segment-keyed)
    var onBilledSeconds: ((Double) -> Void)?                // unused (no realtime billing)
    var onSegmentSource: ((UUID, String, Bool) -> Void)?
    var onSegmentTranslation: ((UUID, String) -> Void)?
    var onSegmentAudio: ((UUID, Data) -> Void)?
    var onSegmentCompleted: ((UUID) -> Void)?
    var onCostDollars: ((Double) -> Void)?

    private let sourceLocaleIdentifier: String
    private let targetLanguage: String
    private let translator: any UtteranceTranslator
    private let synthesizer: (any SpeechSynthesisStage)?

    /// Segment close debounce: a finalized result followed by this much
    /// quiet ends the utterance. Short enough to feel live, long enough to
    /// ride out the transcriber's mid-utterance progressive finalization.
    private let segmentCloseDebounce: TimeInterval = 1.0

    // Guards state + the per-connection audio continuation (sendAudio and
    // close arrive from other threads).
    private let lock = NSLock()
    private var _state: LaneSessionState = .idle
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var stt: SpeechTranscriberStage?
    private var intentionallyClosed = false

    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var segmentContinuation: AsyncStream<Segment>.Continuation?

    private struct Segment {
        let id: UUID
        let text: String
    }

    init(label: String,
         sourceLocaleIdentifier: String,
         targetLanguage: String,
         translator: any UtteranceTranslator,
         synthesizer: (any SpeechSynthesisStage)?) {
        self.label = label
        self.sourceLocaleIdentifier = sourceLocaleIdentifier
        self.targetLanguage = targetLanguage
        self.translator = translator
        self.synthesizer = synthesizer
    }

    // MARK: - TranslationLaneSession

    func connect() {
        lock.lock()
        let canConnect: Bool
        switch _state {
        case .idle, .closed: canConnect = true
        default: canConnect = false
        }
        guard canConnect else {
            lock.unlock()
            return
        }
        intentionallyClosed = false
        lock.unlock()
        setState(.connecting)

        // Fresh per-connection plumbing: AsyncStreams are single-consumer,
        // so a reconnect rebuilds them (like the WS client's fresh socket).
        // ~30 s of 200 ms chunks may queue while assets download, mirroring
        // the WS client's pre-open buffer.
        let (audioStream, audioBuilder) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(150))
        let (segmentStream, segmentBuilder) = AsyncStream<Segment>.makeStream()
        let stage = SpeechTranscriberStage(localeIdentifier: sourceLocaleIdentifier, label: label)
        lock.lock()
        audioContinuation = audioBuilder
        segmentContinuation = segmentBuilder
        stt = stage
        lock.unlock()

        startWorker(segments: segmentStream)

        let assembler = SegmentAssembler(
            label: label,
            onUpdate: { [weak self] id, text, isFinal in
                self?.onSegmentSource?(id, text, isFinal)
            },
            onSegmentReady: { [weak self] id, text in
                self?.enqueueSegment(Segment(id: id, text: text))
            }
        )

        let newResultsTask = Task { [weak self] in
            guard let self else { return }
            let results: AsyncThrowingStream<SpeechTranscriberStage.Result, Error>
            do {
                results = try await stage.start()
            } catch {
                self.failConnection("STT start failed: \(error.localizedDescription)")
                return
            }
            // close() may have run during the asset download / analyzer
            // start — don't bring a closed lane's pipeline up.
            if self.isShutdown {
                await stage.finish()
                self.finishSegments()
                return
            }

            let newFeedTask = Task {
                for await pcm16 in audioStream {
                    stage.append(pcm16: pcm16)
                }
            }
            // Self-terminating on shutdown (not just cancellation): close()
            // can race this task's creation and miss the cancel.
            let newTickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard let self, !self.isShutdown else { return }
                    await assembler.tick(debounce: self.segmentCloseDebounce)
                }
            }
            self.withLock {
                self.feedTask = newFeedTask
                self.tickerTask = newTickerTask
            }
            self.setState(.open)
            Log.info("[\(self.label)] staged pipeline open (\(self.sourceLocaleIdentifier) → \(self.targetLanguage))")

            do {
                for try await result in results {
                    await assembler.handle(result)
                }
                // Results ended (finish() finalized the input): hand any
                // remainder to the worker before it drains.
                await assembler.flush()
                self.finishSegments()
            } catch {
                await assembler.flush()
                self.finishSegments()
                self.failConnection("STT stream failed: \(error.localizedDescription)")
            }
        }
        withLock { resultsTask = newResultsTask }
    }

    func close() {
        lock.lock()
        if intentionallyClosed {
            lock.unlock()
            return
        }
        intentionallyClosed = true
        let continuation = audioContinuation
        audioContinuation = nil
        let stage = stt
        lock.unlock()

        continuation?.finish()
        Task { [weak self] in
            // Let the analyzer finalize pending audio; the results loop then
            // flushes the assembler and closes the segment stream, and the
            // worker drains whatever segments remain (costs reported during
            // the drain still count, like the WS post-close drain).
            await stage?.finish()
            guard let self else { return }
            let (feed, ticker, worker, results) = self.withLock {
                (self.feedTask, self.tickerTask, self.workerTask, self.resultsTask)
            }
            feed?.cancel()
            ticker?.cancel()
            self.setState(.closed(nil))
            // Bounded drain (like the WS close timeout): let in-flight
            // translation/TTS finish, but cut them off after a few seconds.
            if let worker {
                let drain = Task { await worker.value }
                let timeout = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    worker.cancel()
                    results?.cancel()
                }
                await drain.value
                timeout.cancel()
            }
            results?.cancel()
        }
    }

    /// True once close() ran or the state is closed — used by long-lived
    /// tasks to self-terminate even if their cancel was racy.
    private var isShutdown: Bool {
        lock.lock()
        defer { lock.unlock() }
        if intentionallyClosed { return true }
        if case .closed = _state { return true }
        return false
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func sendAudio(_ pcm16: Data) {
        lock.lock()
        let continuation = audioContinuation
        lock.unlock()
        continuation?.yield(pcm16)
    }

    // MARK: - Worker (translation + TTS, serialized per lane)

    private func startWorker(segments: AsyncStream<Segment>) {
        let task = Task { [weak self] in
            var context: [TranslationContextPair] = []
            for await segment in segments {
                guard let self else { return }
                if let pair = await self.processSegment(segment, context: context) {
                    context.append(pair)
                    if context.count > 12 { context.removeFirst(context.count - 12) }
                }
                if Task.isCancelled { return }
            }
        }
        withLock { workerTask = task }
    }

    private func enqueueSegment(_ segment: Segment) {
        lock.lock()
        let continuation = segmentContinuation
        lock.unlock()
        continuation?.yield(segment)
    }

    private func finishSegments() {
        lock.lock()
        let continuation = segmentContinuation
        segmentContinuation = nil
        lock.unlock()
        continuation?.finish()
    }

    /// Returns the finished (source, translation) pair for the worker's
    /// rolling context, or nil if the segment failed to translate.
    private func processSegment(_ segment: Segment, context: [TranslationContextPair]) async -> TranslationContextPair? {
        let sourceLanguage = Locale(identifier: sourceLocaleIdentifier).language.languageCode?.identifier
            ?? sourceLocaleIdentifier
        var translation = ""
        var lastError: Error?
        // One retry, matching the plan's "text degradation beats silence":
        // a failed segment shows the source text with a marker and the lane
        // keeps transcribing.
        for attempt in 0..<2 {
            translation = ""
            lastError = nil
            do {
                for try await chunk in translator.translate(segment.text, from: sourceLanguage,
                                                            to: targetLanguage, context: context) {
                    switch chunk {
                    case .delta(let delta):
                        translation += delta
                        onSegmentTranslation?(segment.id, delta)
                    case .usage(let dollars):
                        onCostDollars?(dollars)
                    }
                }
                break
            } catch {
                lastError = error
                // Deltas already shown from a half-finished first attempt
                // can't be unprinted; note the retry so the bubble reads
                // sanely rather than silently concatenating two attempts.
                if attempt == 0, !translation.isEmpty {
                    onSegmentTranslation?(segment.id, " ⟲ ")
                }
            }
        }
        if let lastError {
            Log.warn("[\(label)] translation failed for segment (\(segment.text.prefix(40))…): \(lastError.localizedDescription)")
            onSegmentTranslation?(segment.id, translation.isEmpty ? "⚠️ translation failed" : " ⚠️ incomplete")
            onSegmentCompleted?(segment.id)
            return nil
        }

        if let synthesizer, !translation.isEmpty {
            // Bounded: a render that never delivers its end marker must not
            // wedge the lane's serialized worker — cancelling the loop
            // triggers the stage's onTermination cleanup.
            let speechText = translation
            let language = targetLanguage
            let tts = Task { [weak self] in
                do {
                    for try await chunk in synthesizer.synthesize(text: speechText, languageCode: language) {
                        switch chunk {
                        case .audio(let data):
                            self?.onSegmentAudio?(segment.id, data)
                        case .usage(let dollars):
                            self?.onCostDollars?(dollars)
                        }
                    }
                } catch {
                    // TTS failure is cosmetic: the translation is on screen.
                    self?.log("TTS failed: \(error.localizedDescription)")
                }
            }
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if !Task.isCancelled {
                    self?.log("TTS stalled >60 s — cancelling segment audio")
                    tts.cancel()
                }
            }
            await tts.value
            timeout.cancel()
        }
        onSegmentCompleted?(segment.id)
        return TranslationContextPair(source: segment.text, translation: translation)
    }

    private func log(_ message: String) {
        Log.warn("[\(label)] \(message)")
    }

    // MARK: - State

    private func setState(_ newState: LaneSessionState) {
        lock.lock()
        // Collapse closed→closed like the WS client so observers see one
        // transition per teardown.
        if case .closed = _state, case .closed = newState {
            lock.unlock()
            return
        }
        _state = newState
        lock.unlock()
        onStateChange?(newState)
    }

    private func failConnection(_ reason: String) {
        lock.lock()
        let wasIntentional = intentionallyClosed
        audioContinuation?.finish()
        audioContinuation = nil
        let feed = feedTask
        let ticker = tickerTask
        lock.unlock()
        finishSegments()
        feed?.cancel()
        ticker?.cancel()
        if wasIntentional { return }
        Log.error("[\(label)] \(reason)")
        setState(.closed(reason))
    }
}

/// Utterance assembly from transcriber results. Volatile results REPLACE
/// the segment's tail; finalized results accumulate. A segment closes when
/// finalized text has sat quietly past the debounce (the transcriber
/// finalizes progressively, so "one final result" ≠ "utterance done").
@available(iOS 26.0, *)
private actor SegmentAssembler {
    private let label: String
    private let onUpdate: (UUID, String, Bool) -> Void
    private let onSegmentReady: (UUID, String) -> Void

    private var currentID: UUID?
    private var finalizedText = ""
    private var volatileText = ""
    private var lastEventAt = Date.distantPast
    /// Volatile text that was force-promoted after a long stall; the next
    /// identical final result is swallowed instead of duplicating a bubble.
    private var promotedText: String?

    /// A volatile transcript that hasn't changed for this long with no
    /// finalization is promoted anyway — belt and braces against a stuck
    /// finalizer; normally the transcriber finalizes on pauses well before.
    private let stallPromotion: TimeInterval = 6.0

    init(label: String,
         onUpdate: @escaping (UUID, String, Bool) -> Void,
         onSegmentReady: @escaping (UUID, String) -> Void) {
        self.label = label
        self.onUpdate = onUpdate
        self.onSegmentReady = onSegmentReady
    }

    func handle(_ result: SpeechTranscriberStage.Result) {
        let text = result.text
        guard !text.isEmpty else { return }
        if result.isFinal, currentID == nil, text == promotedText {
            Log.info("[\(label)] swallowed late final for force-promoted segment")
            promotedText = nil
            return
        }
        // Any other result means the stall resolved with different content —
        // the swallow window is over (a stale promotedText must never eat a
        // genuine repeat of the same phrase minutes later).
        promotedText = nil
        let id: UUID
        if let currentID {
            id = currentID
        } else {
            id = UUID()
            currentID = id
        }
        if result.isFinal {
            finalizedText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        lastEventAt = Date()
        onUpdate(id, finalizedText + volatileText, false)
    }

    /// Driven by the client's ~300 ms ticker.
    func tick(debounce: TimeInterval) {
        guard let id = currentID else { return }
        let quiet = Date().timeIntervalSince(lastEventAt)
        if !finalizedText.isEmpty, volatileText.isEmpty, quiet > debounce {
            closeSegment(id)
        } else if !volatileText.isEmpty, quiet > stallPromotion {
            // Covers both stalled shapes: nothing finalized yet, or a
            // finalized head with a volatile tail the recognizer abandoned.
            Log.warn("[\(label)] volatile transcript stalled \(Int(quiet))s without finalization — promoting")
            promotedText = finalizedText.isEmpty ? volatileText : nil
            finalizedText += volatileText
            volatileText = ""
            closeSegment(id)
        }
    }

    /// On teardown: whatever is buffered — volatile included — beats
    /// dropping the speaker's last words.
    func flush() {
        guard let id = currentID else { return }
        finalizedText += volatileText
        volatileText = ""
        guard !finalizedText.isEmpty else {
            currentID = nil
            return
        }
        closeSegment(id)
    }

    private func closeSegment(_ id: UUID) {
        let text = finalizedText
        currentID = nil
        finalizedText = ""
        volatileText = ""
        onUpdate(id, text, true)
        onSegmentReady(id, text)
    }
}
