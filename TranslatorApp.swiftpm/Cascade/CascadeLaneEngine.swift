import Foundation
import AVFoundation
import Translation

/// The cascade lane engine (docs/CASCADE-PIPELINE.md §6–§7, §14):
/// gate-passed audio → AnalyzerPool slot (STT) → the conversation's
/// `Translator` (shared Apple session, or per-lane OpenAI with Apple
/// fallback) → per-lane AppleSpeechSynth → 24 kHz PCM16 out through the
/// existing playback seam.
///
/// Threading: all mutable state is confined to `queue`. Pool interactions
/// are serialized IN ORDER through one worker task consuming a command
/// stream (unstructured Tasks would not preserve audio ordering); results
/// and provider completions hop back onto the queue.
final class CascadeLaneEngine: LaneEngine {

    let label: String

    var onState: ((LaneEngineState) -> Void)?
    var onNotice: ((LaneNotice) -> Void)?
    var onTranscript: ((TranscriptEvent) -> Void)?
    var onTranslatedAudio: ((Data) -> Void)?
    var onCostDelta: ((Double) -> Void)?     // cloud MT token cost ($0 all-Apple)
    var onMetric: ((LaneMetric) -> Void)?
    /// A NON-FALLBACK translation finalized: (sourceText, translation).
    /// AppModel appends it to the shared context window on main and
    /// pushes the window back into every cascade engine (§14.1).
    var onTranslationPair: ((String, String) -> Void)?

    private let lane: Int
    private let queue: DispatchQueue
    private let context: CascadeContext
    private let translator: any Translator
    private let synth: AppleSpeechSynth

    // MARK: - Pool worker (order-preserving bridge to the actor)

    private enum Command {
        case waitReady
        case acquire(epoch: Int)
        case feed(AVAudioPCMBuffer)
        case padSilence
        case finishSlot
        case release
        case teardownLane
    }

    private var commands: AsyncStream<Command>.Continuation!
    private var worker: Task<Void, Never>?

    // MARK: - Queue-confined state

    private var closed = false
    private var ready = false
    private var readinessFailed = false
    private var analyzerFormat: AVAudioFormat?
    /// Input converter, rebuilt when the incoming hardware format changes
    /// (the seam's self-healing rule — a stale converter here fails
    /// silently).
    private var inputConverter: AVAudioConverter?
    private var inputRate: Double = 0

    /// Lane-side audio buffer (converted to the analyzer format): holds
    /// the pre-acquisition backlog under contention AND the post-release
    /// hangover tail (§6.1.1). Bounded to ~30 s, drop-oldest.
    private var laneBuffer: [AVAudioPCMBuffer] = []
    private var laneBufferSeconds: Double = 0
    private static let laneBufferCapSeconds: Double = 30

    private enum SlotState {
        case none
        case acquiring
        case held
        /// Close requested; the worker is finishing the slot (finals
        /// arrive DURING the finish and must still be accepted).
        case finishing
    }
    private var slotState: SlotState = .none
    /// Bumped at every settle: results are stamped with the epoch their
    /// slot was acquired under, so a straggler final flushing from a
    /// retiring slot can never attach to the NEXT utterance even if it
    /// already acquired a fresh slot (the timed-out-settle race).
    private var slotEpoch = 0

    /// One utterance flowing through capture → finalize; MT/TTS stages
    /// track their own queues below.
    private struct Utterance {
        let id: UUID
        let openedAt: Date
        /// Finalized sub-segment texts already released downstream
        /// mid-utterance (punctuated finals), NOT re-released at close.
        var volatileText: String = ""
        var finalParts: [String] = []
        var lastVoicedNowAt: Date
        var closeRequestedAt: Date?
        /// Field-debugging counters: whether STT results flowed at all for
        /// this utterance is the first question every misbehavior report
        /// asks.
        var volatileEvents = 0
        var finalEvents = 0
    }
    private var current: Utterance?

    private struct TranslationJob {
        let id: UUID
        let sourceText: String
        let speechEndedAt: Date?
    }
    private var mtQueue: [TranslationJob] = []
    private var mtInFlight = false
    /// The in-flight job's id, for delta correlation — a straggler delta
    /// from a resolved job must not repaint the bubble.
    private var mtInFlightJob: UUID?
    private var translationDead = false
    /// Cached copy of the cross-lane context window, PUSHED by AppModel
    /// (never pulled — a lane-queue → main sync fetch would ABBA-deadlock
    /// against the 1 Hz snapshot() sync, §14.1).
    private var translationContext: [TranslationContextPair] = []

    private struct TTSJob {
        let id: UUID
        let text: String
        let speechEndedAt: Date?
        let submittedAt: Date
    }
    private var ttsQueue: [TTSJob] = []
    private var ttsInFlight: TTSJob?
    private var ttsFirstAudioSeen = false
    private static let maxUnspokenBacklog = 3

    // Stats for the Diagnostics snapshot.
    private var stats = CascadeSnapshot(
        state: .idle, utterancesOpened: 0, utterancesFinalized: 0,
        utterancesTranslated: 0, utterancesSpoken: 0, volatileChars: 0,
        finalChars: 0, slotWaits: 0, lastSlotWaitSeconds: nil,
        holdsSlot: false, bufferedAudioSeconds: 0, audioSkips: 0,
        lastFinalizeSeconds: nil, lastTranslateSeconds: nil,
        lastTTSFirstAudioSeconds: nil, lastError: nil,
        translationProvider: "apple", mtFallbacks: 0,
        mtFallbackUnavailable: false
    )

    private var state: LaneEngineState = .idle {
        didSet {
            if state != oldValue {
                stats.state = state
                onState?(state)
            }
        }
    }

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?"]
    private static let fastCloseSeconds: TimeInterval = 0.4
    private static let slowCloseSeconds: TimeInterval = 0.75
    private static let maxUtteranceSeconds: TimeInterval = 12
    /// Bounded wait for the close's final result before settling with the
    /// volatile text (~95% identical on short utterances per research).
    /// Deliberately short: waiting long buys little accuracy and costs
    /// every utterance's latency when finalization is slow.
    private static let finalWaitSeconds: TimeInterval = 1.2

    init(lane: Int, context: CascadeContext, translator: any Translator,
         voiceIdentifier: String, speechRate: Double) {
        self.lane = lane
        self.context = context
        self.translator = translator
        self.label = "cascade ch\(lane)"
        self.queue = DispatchQueue(label: "translator.cascade.lane.\(lane)")
        self.synth = AppleSpeechSynth(
            lane: lane,
            voiceIdentifier: voiceIdentifier,
            rate: speechRate,
            languageHint: context.targetLanguageCode
        )
        stats.translationProvider = context.translationProviderLabel
        wireSynth()
        wireTranslator()
        startWorker()
    }

    /// The pushed context window (see translationContext). Callable from
    /// any thread; fire-and-forget.
    func updateTranslationContext(_ window: [TranslationContextPair]) {
        queue.async { self.translationContext = window }
    }

    // MARK: - LaneEngine

    func start() {
        queue.async {
            guard !self.closed, self.state == .idle else { return }
            self.state = .starting
            self.commands.yield(.waitReady)
            self.synth.prewarm()
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            // Per-utterance slots: a lane close finishes its in-flight
            // slot (the pool retires it and spawns a replacement) — the
            // old lanes-never-finish rule died with long-lived slots.
            if self.slotState != .none { self.commands.yield(.teardownLane) }
            self.commands.finish()
            self.mtQueue.removeAll()
            self.ttsQueue.removeAll()
            self.synth.cancelAll()
            self.laneBuffer.removeAll()
            self.laneBufferSeconds = 0
            self.state = .idle
        }
    }

    func sendAudio(_ buffer: AVAudioPCMBuffer, verdict: GateVerdict) {
        queue.async { self.processAudio(buffer, verdict: verdict) }
    }

    func snapshot() -> LaneEngineSnapshot {
        queue.sync {
            var copy = stats
            copy.holdsSlot = slotState == .held || slotState == .finishing
            copy.bufferedAudioSeconds = laneBufferSeconds
            return .cascade(copy)
        }
    }

    // MARK: - Capture & segmentation (queue-confined)

    private func processAudio(_ buffer: AVAudioPCMBuffer, verdict: GateVerdict) {
        guard !closed, !readinessFailed else { return }
        let now = Date()

        // Utterance close checks run on every tap buffer (~200 ms
        // resolution), including non-pass ones — that IS the debounce
        // clock.
        if var utterance = current {
            if verdict.voicedNow && verdict.pass {
                utterance.lastVoicedNowAt = now
                current = utterance
            }
            let quiet = now.timeIntervalSince(utterance.lastVoicedNowAt)
            let threshold = endsWithSentenceEnder(utterance.volatileText)
                ? Self.fastCloseSeconds : Self.slowCloseSeconds
            if utterance.closeRequestedAt == nil {
                if quiet > threshold {
                    requestClose(reason: "quiet \(String(format: "%.2f", quiet))s")
                } else if now.timeIntervalSince(utterance.openedAt) > Self.maxUtteranceSeconds {
                    // 12 s hard split: a normal close — per-utterance
                    // slots mean the follow-on utterance simply acquires
                    // the next slot; interim audio bridges in the lane
                    // buffer.
                    requestClose(reason: "12s split")
                }
            }
        }

        // Only gate-passed audio is captured (silence is a realtime-wire
        // artifact; §6.1 input rule).
        guard verdict.pass else { return }
        guard ready else {
            // Pre-readiness speech still buffers (bounded) so the first
            // words after Start aren't lost while the pool builds.
            if let converted = convertInput(buffer) { appendToLaneBuffer(converted) }
            return
        }

        // Open on genuine voicing when no utterance is in flight.
        if current == nil, verdict.voicedNow, !closed {
            openUtterance(at: now)
        }

        guard let converted = convertInput(buffer) else { return }
        // Feed the slot ONLY while an utterance is open AND its close
        // has not been requested — post-close audio belongs to the NEXT
        // utterance (this slot is about to be finished and retired).
        // Everything else (slot wait, post-close tail, resumed speech
        // racing a close) lands in the lane buffer and burst-feeds at
        // the next acquisition.
        if let utterance = current, utterance.closeRequestedAt == nil, slotState == .held {
            commands.yield(.feed(converted))
        } else {
            appendToLaneBuffer(converted)
        }
    }

    private func openUtterance(at now: Date) {
        let utterance = Utterance(id: UUID(), openedAt: now, lastVoicedNowAt: now)
        current = utterance
        stats.utterancesOpened += 1
        if slotState == .none {
            slotState = .acquiring
            commands.yield(.acquire(epoch: slotEpoch))
        }
    }

    private func requestClose(reason: String) {
        guard var utterance = current, utterance.closeRequestedAt == nil else { return }
        utterance.closeRequestedAt = Date()
        current = utterance
        Log.info("[\(label)] utterance close (\(reason))")
        if slotState == .held {
            // Silence pad (end-of-speech evidence), then finish the slot:
            // the finish flushes the final result (probe-proven ~0.1 s)
            // and retires the slot; a replacement builds in the pool.
            commands.yield(.padSilence)
            commands.yield(.finishSlot)
            slotState = .finishing
        }
        // Bounded wait for the final result: if the analyzer recognized
        // nothing (or the slot was never acquired), settle with the
        // volatile text rather than hanging the lane.
        let id = utterance.id
        queue.asyncAfter(deadline: .now() + Self.finalWaitSeconds) { [weak self] in
            guard let self, let stuck = self.current, stuck.id == id,
                  stuck.closeRequestedAt != nil else { return }
            let text = (stuck.finalParts + [stuck.volatileText]).joined()
            // The result counts are the diagnosis: 0V/0F = the analyzer
            // returned NOTHING for this utterance (wedged slot or format
            // problem); NV/0F = volatiles flow but finalize never flushes.
            Log.warn("[\(self.label)] no final within \(Self.finalWaitSeconds)s — settling with \(text.count) chars of volatile text (results: \(stuck.volatileEvents)V/\(stuck.finalEvents)F)")
            self.settleUtterance(finalText: text, timedOut: true)
        }
    }

    /// Punctuated mid-utterance final (§6.1 sub-segmentation): the text is
    /// ALREADY final — release it downstream and keep capturing under a
    /// fresh UUID on the same slot. No finalize command: nothing dangles
    /// (the final covered its range) and the stream simply continues.
    private func releaseSubSegment(_ utterance: Utterance, finalText: String) {
        Log.info("[\(label)] utterance sub-segmented (sentence final)")
        finishUtterance(utterance, finalText: finalText)
        current = Utterance(id: UUID(), openedAt: Date(), lastVoicedNowAt: Date())
        stats.utterancesOpened += 1
    }


    // MARK: - Pool worker

    private func startWorker() {
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        worker = Task { [weak self] in
            guard let self else { return }
            var slot: Int?
            for await command in stream {
                switch command {
                case .waitReady:
                    let readiness = await self.context.ready()
                    self.queue.async { self.readinessResolved(readiness) }
                case .acquire(let epoch):
                    let waitStart = Date()
                    let granted = await self.context.pool.acquire(onResult: { [weak self] event in
                        self?.queue.async { self?.handleResult(event, epoch: epoch) }
                    })
                    slot = granted
                    let wait = Date().timeIntervalSince(waitStart)
                    self.queue.async { self.slotGranted(granted != nil, epoch: epoch, waitSeconds: wait) }
                case .feed(let buffer):
                    if let slot { await self.context.pool.feed(slotIndex: slot, buffer: buffer) }
                case .padSilence:
                    if let slot { await self.context.pool.feedSilence(slotIndex: slot, seconds: 0.6) }
                case .finishSlot:
                    if let slot { await self.context.pool.finishAndRetire(slotIndex: slot) }
                    slot = nil
                case .release:
                    if let slot { await self.context.pool.release(slotIndex: slot) }
                    slot = nil
                case .teardownLane:
                    if let slot { await self.context.pool.finishAndRetire(slotIndex: slot) }
                    slot = nil
                }
            }
            if let remaining = slot {
                await self.context.pool.release(slotIndex: remaining)
            }
        }
    }

    private func readinessResolved(_ readiness: CascadeContext.Readiness) {
        guard !closed else { return }
        if let failure = readiness.failureText {
            readinessFailed = true
            state = .failed(failure)
            onNotice?(.raised(id: "cascade.\(lane)", text: failure))
            return
        }
        analyzerFormat = readiness.analyzerFormat
        ready = true
        state = .running
        // Pre-readiness ambient audio older than a few seconds would lead
        // the NEXT utterance as unrelated context — keep the buffer only
        // if it's fresh (likely the user's first words after Start).
        if current == nil, Date().timeIntervalSince(lastLaneBufferAppendAt) > 3 {
            laneBuffer.removeAll()
            laneBufferSeconds = 0
        }
        if readiness.poolSize < 4 {
            Log.info("[\(label)] analyzer pool size \(readiness.poolSize) — lanes share slots per utterance")
        }
    }

    private func slotGranted(_ granted: Bool, epoch: Int, waitSeconds: Double) {
        guard !closed else { return }
        guard granted else {
            slotState = .none
            // nil grants now mean teardown or a never-built pool
            // (transient zero-live waits pool-side).
            if current != nil {
                state = .failed("speech model unavailable — check Settings → Translation pipeline")
            }
            return
        }
        // STALE grant: this acquire belonged to an utterance that already
        // settled (epoch bumped). Nothing has been fed on this binding,
        // so the slot is genuinely virgin — hand it back, and if a LIVE
        // utterance is riding the standing acquire, re-acquire under the
        // current epoch so its results aren't epoch-dropped (review:
        // standing acquires silently swallowed the successor utterance
        // under contention).
        if epoch != slotEpoch {
            commands.yield(.release)
            if current != nil {
                commands.yield(.acquire(epoch: slotEpoch))
                slotState = .acquiring
            } else {
                slotState = .none
            }
            return
        }
        // Grant landing inside a close's settle window: feeds are blocked
        // (closeRequestedAt set), so the slot is virgin — return it
        // rather than finishing a slot that never heard the audio; the
        // utterance settles from its volatile state.
        if current?.closeRequestedAt != nil {
            commands.yield(.release)
            slotState = .none
            return
        }
        if current == nil {
            // The acquire landed after its utterance settled (the
            // final-wait timeout raced a long slot queue): there is no
            // utterance to serve, so release immediately rather than
            // squatting on a shared slot — the lane buffer keeps the tail
            // for the next open, which will re-acquire.
            slotState = .none
            commands.yield(.release)
            return
        }
        slotState = .held
        // A successful grant proves the pool recovered — a lane reddened
        // by a nil grant must not stay failed forever.
        if case .failed = state { state = .running }
        // Count only genuine contention (an uncontended grant is a few ms
        // of actor hop) so the Diagnostics "waits" line means something.
        if waitSeconds > 0.05 {
            stats.slotWaits += 1
            stats.lastSlotWaitSeconds = waitSeconds
        }
        if waitSeconds > 2 {
            state = .degraded("waiting for a speech model — simultaneous speech may lag")
        } else if case .degraded = state {
            state = .running
        }
        // Burst-feed the backlog (pre-acquisition speech + any buffered
        // tail) IN ORDER before any live buffer that arrives after this
        // hop.
        for buffer in laneBuffer { commands.yield(.feed(buffer)) }
        laneBuffer.removeAll()
        laneBufferSeconds = 0
    }

    // MARK: - STT results (queue-confined)

    private func handleResult(_ event: AnalyzerPool.ResultEvent, epoch: Int) {
        guard epoch == slotEpoch, !closed, var utterance = current else { return }
        // Trust results only while a slot is legitimately bound to this
        // utterance: .held (live capture) or .finishing (the close's
        // finish is flushing the final). After a timed-out settle the
        // state is .none until the next acquisition, and a retired slot's
        // stragglers are dropped pool-side (owner unbound at retire) — no
        // cross-utterance attribution is possible with per-utterance
        // slots.
        guard slotState == .held || slotState == .finishing else { return }
        if event.isFinal {
            stats.finalChars += event.text.count
            utterance.finalEvents += 1
            if !event.text.isEmpty {
                utterance.finalParts.append(event.text)
                utterance.volatileText = ""
            }
            current = utterance
            let joined = utterance.finalParts.joined()
            // An empty final after visible volatiles must not wipe them.
            let effective = joined.isEmpty ? utterance.volatileText : joined
            if utterance.closeRequestedAt != nil {
                // The close's finalize delivered — settle now.
                settleUtterance(finalText: effective, timedOut: false)
            } else if endsWithSentenceEnder(joined) {
                releaseSubSegment(utterance, finalText: joined)
            } else if !joined.isEmpty {
                onTranscript?(.sourceText(utterance: utterance.id, text: joined, isFinal: false))
            }
        } else {
            stats.volatileChars += event.text.count
            utterance.volatileEvents += 1
            utterance.volatileText = event.text
            current = utterance
            let display = (utterance.finalParts + [event.text]).joined()
            onTranscript?(.sourceText(utterance: utterance.id, text: display, isFinal: false))
        }
    }

    /// Close path completion: emit the final source text, release the
    /// slot, and hand the utterance to MT.
    private func settleUtterance(finalText: String, timedOut: Bool) {
        guard let utterance = current else { return }
        if let closeAt = utterance.closeRequestedAt, !timedOut {
            let seconds = Date().timeIntervalSince(closeAt)
            stats.lastFinalizeSeconds = seconds
            onMetric?(.sttFinalizeSeconds(seconds))
            Log.info("[\(label)] settled with final (\(finalText.count) chars, finalize \(String(format: "%.2f", seconds))s, results \(utterance.volatileEvents)V/\(utterance.finalEvents)F)")
        }
        current = nil
        slotEpoch += 1
        switch slotState {
        case .finishing:
            // The worker's finishSlot retires the slot and the pool
            // spawns a replacement; nothing more to do here.
            slotState = .none
        case .held:
            // Defensive: unreachable after the grant-window guards above
            // (requestClose converts held→finishing; post-close grants
            // are released at slotGranted). Virgin by those guards.
            commands.yield(.release)
            slotState = .none
        case .acquiring, .none:
            // A pending acquire is left standing; slotGranted releases it
            // immediately if no new utterance opened by then.
            break
        }
        finishUtterance(utterance, finalText: finalText)
    }

    /// Shared by settle and rotate: transcript final + MT enqueue.
    private func finishUtterance(_ utterance: Utterance, finalText: String) {
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        stats.utterancesFinalized += 1
        if text.isEmpty {
            Log.warn("[\(label)] utterance produced NO text (results: \(utterance.volatileEvents)V/\(utterance.finalEvents)F) — nothing recognized, or STT results are not flowing on this slot")
        }
        guard !text.isEmpty else {
            // Nothing recognized: close the bubble (if volatiles ever
            // opened one) WITHOUT wiping the text it shows — the store
            // ignores this event when no bubble exists.
            onTranscript?(.translationText(utterance: utterance.id, text: "", isFinal: true))
            return
        }
        onTranscript?(.sourceText(utterance: utterance.id, text: text, isFinal: true))
        mtQueue.append(TranslationJob(id: utterance.id, sourceText: text, speechEndedAt: utterance.closeRequestedAt))
        pumpMT()
    }

    // MARK: - Translation stage (queue-confined; one in flight per lane)

    /// Per-instance wiring: correct for per-lane providers (OpenAI); the
    /// shared Apple instance gets clobbered by whichever lane wired last
    /// but never fires either callback (see the Translator protocol).
    private func wireTranslator() {
        translator.onDelta = { [weak self] job, text in
            self?.queue.async {
                guard let self, !self.closed, self.mtInFlightJob == job, !text.isEmpty else { return }
                self.onTranscript?(.translationText(utterance: job, text: text, isFinal: false))
            }
        }
        // No queue hop: AppModel's sink (CostMeter) is thread-safe, same
        // as the realtime engine's billing path.
        translator.onCostDelta = { [weak self] dollars in
            self?.onCostDelta?(dollars)
        }
    }

    private func pumpMT() {
        guard !mtInFlight, !closed, let job = mtQueue.first else { return }
        mtQueue.removeFirst()
        if translationDead {
            onTranscript?(.translationText(utterance: job.id, text: "", isFinal: true))
            pumpMT()
            return
        }
        mtInFlight = true
        mtInFlightJob = job.id
        // The cached PUSHED window as of this submit — utterance N ships
        // with the window as of the previous finalization, which is the
        // intended content (N itself is excluded by rule anyway, §14.1).
        let window = translationContext
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.translator.translate(job.sourceText, context: window, job: job.id)
                self.queue.async { self.mtFinished(job: job, result: result, started: started, error: nil) }
            } catch {
                self.queue.async { self.mtFinished(job: job, result: nil, started: started, error: error) }
            }
        }
    }

    private func mtFinished(job: TranslationJob, result: TranslationResult?, started: Date, error: Error?) {
        mtInFlight = false
        mtInFlightJob = nil
        guard !closed else { return }
        if let result {
            let seconds = Date().timeIntervalSince(started)
            stats.lastTranslateSeconds = seconds
            stats.utterancesTranslated += 1
            onMetric?(.translationSeconds(seconds))
            onTranscript?(.translationText(utterance: job.id, text: result.text, isFinal: true))
            // ANY success clears the missing-fallback-pack symptom: either
            // the pack got installed mid-conversation (fallback succeeded)
            // or the cloud recovered (the symptom's "cloud failing" half
            // is gone) — a stale "download it" row misleads (review NIT).
            stats.mtFallbackUnavailable = false
            if result.viaFallback {
                // Fallback pairs stay OUT of the shared context window —
                // they'd teach the literal style the cloud provider
                // exists to avoid (§14.1).
                stats.mtFallbacks += 1
            } else {
                onTranslationPair?(job.sourceText, result.text)
            }
            enqueueTTS(TTSJob(id: job.id, text: result.text, speechEndedAt: job.speechEndedAt, submittedAt: Date()))
        } else {
            let description = error?.localizedDescription ?? "unknown"
            stats.lastError = "translate: \(description)"
            Log.error("[\(label)] translation failed: \(description)")
            onTranscript?(.translationText(utterance: job.id, text: "", isFinal: true))
            if let stage = error as? TranslationStageError, case .fallbackUnavailable = stage {
                // Cloud MT failing AND no offline pack: every outage shows
                // "—" — surface the missing-pack symptom in Diagnostics.
                stats.mtFallbackUnavailable = true
            }
            // A missing pack is stage-fatal but must not kill capture
            // (§8.2): transcription continues, translations show "—".
            // Typed check (TranslationError.notInstalled has a ~= operator
            // over `any Error`) — matching localizedDescription would
            // break on non-English device locales. Only the Apple-PRIMARY
            // path ever surfaces it: the OpenAI translator maps a
            // missing FALLBACK pack to TranslationStageError, so a
            // recoverable cloud stage is never killed here.
            if let error, TranslationError.notInstalled ~= error {
                translationDead = true
                onNotice?(.raised(
                    id: "cascade.mt.\(lane)",
                    text: "Translation pack removed — transcripts continue; reinstall the pack in Settings → Translation pipeline."
                ))
            }
        }
        pumpMT()
    }

    // MARK: - TTS stage (queue-confined; one job submitted at a time)

    private func wireSynth() {
        synth.onAudio = { [weak self] job, data in
            self?.queue.async {
                guard let self, !self.closed, self.ttsInFlight?.id == job else { return }
                if !self.ttsFirstAudioSeen {
                    self.ttsFirstAudioSeen = true
                    let inFlight = self.ttsInFlight
                    let ttfb = Date().timeIntervalSince(inFlight?.submittedAt ?? Date())
                    self.stats.lastTTSFirstAudioSeconds = ttfb
                    self.onMetric?(.ttsFirstAudioSeconds(ttfb))
                    if let ended = inFlight?.speechEndedAt {
                        self.onMetric?(.endToEndSeconds(Date().timeIntervalSince(ended)))
                    }
                }
                self.onTranslatedAudio?(data)
            }
        }
        synth.onFinished = { [weak self] job, error in
            self?.queue.async {
                guard let self, self.ttsInFlight?.id == job else { return }
                if let error {
                    self.stats.lastError = "tts: \(error)"
                    Log.warn("[\(self.label)] TTS job failed: \(error)")
                } else {
                    self.stats.utterancesSpoken += 1
                }
                self.ttsInFlight = nil
                self.pumpTTS()
            }
        }
    }

    private func enqueueTTS(_ job: TTSJob) {
        ttsQueue.append(job)
        // Backpressure (§7): stale speech is worse than a visible
        // transcript — past the backlog cap, drop the OLDEST queued
        // (not in-flight) audio; its translation stays on screen.
        while ttsQueue.count > Self.maxUnspokenBacklog {
            let dropped = ttsQueue.removeFirst()
            stats.audioSkips += 1
            Log.warn("[\(label)] TTS backlog — skipping audio for “\(dropped.text.prefix(40))…” (transcript kept)")
        }
        pumpTTS()
    }

    private func pumpTTS() {
        guard ttsInFlight == nil, !closed, !ttsQueue.isEmpty else { return }
        let job = ttsQueue.removeFirst()
        ttsInFlight = TTSJob(id: job.id, text: job.text, speechEndedAt: job.speechEndedAt, submittedAt: Date())
        ttsFirstAudioSeen = false
        synth.synthesize(text: job.text, job: job.id)
    }

    // MARK: - Helpers

    private func convertInput(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = analyzerFormat ?? fallbackAnalyzerFormat() else { return nil }
        let rate = buffer.format.sampleRate
        // Rebuild on INPUT rate change (route churn) AND on OUTPUT format
        // change (readiness swapping the fallback guess for the pool's
        // real analyzer format) — a converter stuck on the fallback would
        // feed the analyzer wrong-format audio for the whole
        // conversation, which fails silently (§2.2).
        if inputConverter == nil || inputRate != rate || inputConverter?.outputFormat != format {
            if inputConverter != nil {
                Log.info("[\(label)] STT converter rebuilt (\(Int(rate)) Hz in → \(Int(format.sampleRate)) Hz out)")
            }
            inputConverter = AVAudioConverter(from: buffer.format, to: format)
            inputRate = rate
        }
        guard let converter = inputConverter else { return nil }
        let ratio = format.sampleRate / rate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Pre-readiness conversions target 16 kHz mono int16 (the measured
    /// analyzer format). If the pool's real format differs, the rebuild
    /// rule above re-converts nothing retroactively — the pre-readiness
    /// buffers are sacrificed (bounded by the 3 s staleness drop) and the
    /// converter self-heals for everything after.
    private func fallbackAnalyzerFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    }

    private var lastLaneBufferAppendAt = Date.distantPast

    private func appendToLaneBuffer(_ buffer: AVAudioPCMBuffer) {
        lastLaneBufferAppendAt = Date()
        laneBuffer.append(buffer)
        laneBufferSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        while laneBufferSeconds > Self.laneBufferCapSeconds, !laneBuffer.isEmpty {
            let dropped = laneBuffer.removeFirst()
            laneBufferSeconds -= Double(dropped.frameLength) / dropped.format.sampleRate
        }
    }

    /// Closing quotes/brackets legitimately trail a sentence ender
    /// (same set TranscriptStore's completeness check skips).
    private static let trailingClosers: Set<Character> = ["\"", "\u{201D}", "\u{2019}", "'", ")", "）", "」", "』", "]", "】"]

    private func endsWithSentenceEnder(_ text: String) -> Bool {
        for char in text.reversed() {
            if char.isWhitespace || Self.trailingClosers.contains(char) { continue }
            return Self.sentenceEnders.contains(char)
        }
        return false
    }
}
