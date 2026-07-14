import Foundation
import AVFoundation
import Translation

/// The on-device cascade lane engine (docs/CASCADE-PIPELINE.md §6–§7):
/// gate-passed audio → AnalyzerPool slot (STT) → shared AppleTranslator →
/// per-lane AppleSpeechSynth → 24 kHz PCM16 out through the existing
/// playback seam. Free, offline, per-lane voice.
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
    var onCostDelta: ((Double) -> Void)?     // never fires: on-device, $0
    var onMetric: ((LaneMetric) -> Void)?

    private let lane: Int
    private let queue: DispatchQueue
    private let context: CascadeContext
    private let synth: AppleSpeechSynth

    // MARK: - Pool worker (order-preserving bridge to the actor)

    private enum Command {
        case waitReady
        case acquire
        case feed(AVAudioPCMBuffer)
        case padSilence
        case finalize
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
    }
    private var slotState: SlotState = .none

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
    private var translationDead = false

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
        lastTTSFirstAudioSeconds: nil, lastError: nil
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

    init(lane: Int, context: CascadeContext, voiceIdentifier: String, speechRate: Double) {
        self.lane = lane
        self.context = context
        self.label = "cascade ch\(lane)"
        self.queue = DispatchQueue(label: "translator.cascade.lane.\(lane)")
        self.synth = AppleSpeechSynth(
            lane: lane,
            voiceIdentifier: voiceIdentifier,
            rate: speechRate,
            languageHint: context.targetLanguageCode
        )
        wireSynth()
        startWorker()
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
            // Lane close releases — never finishes — its slot (§7):
            // slots are shared; only CascadeContext.teardown() at Stop
            // finishes analyzers.
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
            copy.holdsSlot = slotState == .held
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
                    requestClose(reason: "quiet \(String(format: "%.2f", quiet))s", keepSlot: false)
                } else if now.timeIntervalSince(utterance.openedAt) > Self.maxUtteranceSeconds {
                    // 12 s hard split: a normal full-cursor close that
                    // KEEPS the slot — capture continues under a new
                    // utterance the moment the final lands (audio bridges
                    // the ~0.1 s finalize wait in the lane buffer).
                    requestClose(reason: "12s split", keepSlot: true)
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
        // Feed the slot ONLY while an utterance is open AND its close has
        // not been requested: audio fed after the finalize command would
        // sit un-finalized on the slot's timeline at release — the exact
        // dangling-region hazard the full-cursor rule exists to prevent.
        // Everything else (slot wait, post-close tail, resumed speech
        // racing a close) lands in the lane buffer and burst-feeds at the
        // next acquisition.
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
            commands.yield(.acquire)
        }
    }

    private func requestClose(reason: String, keepSlot: Bool) {
        guard var utterance = current, utterance.closeRequestedAt == nil else { return }
        utterance.closeRequestedAt = Date()
        current = utterance
        settleKeepsSlot = keepSlot && slotState == .held
        Log.info("[\(label)] utterance close (\(reason))")
        if slotState == .held {
            // Silence pad first: end-of-speech evidence + input progress
            // past the boundary, without which the transcriber was
            // observed never flushing its finalization on-device.
            commands.yield(.padSilence)
            commands.yield(.finalize)
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

    /// Set when a close should hand its slot straight to the follow-on
    /// utterance (the 12 s split) instead of releasing it.
    private var settleKeepsSlot = false
    /// Set by a timed-out settle: the finalize's real final may still be
    /// in flight, and the next final to arrive on this lane is that
    /// straggler — swallow it instead of attributing it to a newer
    /// utterance.
    private var staleDropUntilFinal = false

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
                case .acquire:
                    let waitStart = Date()
                    let granted = await self.context.pool.acquire(onResult: { [weak self] event in
                        self?.queue.async { self?.handleResult(event) }
                    })
                    slot = granted
                    let wait = Date().timeIntervalSince(waitStart)
                    self.queue.async { self.slotGranted(granted != nil, waitSeconds: wait) }
                case .feed(let buffer):
                    if let slot { await self.context.pool.feed(slotIndex: slot, buffer: buffer) }
                case .padSilence:
                    if let slot { await self.context.pool.feedSilence(slotIndex: slot, seconds: 0.6) }
                case .finalize:
                    if let slot { await self.context.pool.finalizeCurrent(slotIndex: slot) }
                case .release:
                    if let slot { await self.context.pool.release(slotIndex: slot) }
                    slot = nil
                case .teardownLane:
                    if let slot {
                        await self.context.pool.finalizeCurrent(slotIndex: slot)
                        await self.context.pool.release(slotIndex: slot)
                    }
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

    private func slotGranted(_ granted: Bool, waitSeconds: Double) {
        guard !closed else { return }
        guard granted else {
            slotState = .none
            // The pool died underneath us (all slots retired).
            if current != nil {
                state = .failed("speech model failed — restart the conversation")
            }
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
        // A fresh binding can never receive the previous binding's
        // straggler (the pool drops unowned results and the .held guard
        // covered the released window) — clear the latch so it can't eat
        // this utterance's genuine final.
        staleDropUntilFinal = false
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

    private func handleResult(_ event: AnalyzerPool.ResultEvent) {
        guard !closed, var utterance = current else { return }
        // Trust results only while a slot is legitimately bound: after a
        // timed-out settle released the slot, a straggler final from the
        // old range must not land in the next utterance (duplicated
        // speech) — slotState is .none until re-acquisition, and for the
        // keep-slot (12 s split) timeout the flag below swallows exactly
        // the stale final. If the stale final never comes, the next
        // genuine one is sacrificed and that settle degrades to its
        // volatile text — graceful, logged, and rare.
        guard slotState == .held else { return }
        if staleDropUntilFinal {
            if event.isFinal {
                staleDropUntilFinal = false
            } else {
                // Volatiles while latched are (almost certainly) the NEW
                // range's speech — keep them in the utterance so a
                // timeout settle still degrades to text rather than to
                // silence; they're just not displayed while the straggler
                // could contaminate them.
                utterance.volatileText = event.text
                current = utterance
            }
            return
        }
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
        if settleKeepsSlot, slotState == .held {
            // 12 s split: hand the slot straight to the follow-on
            // utterance and flush the audio buffered during the finalize
            // wait as its opening context. This is the ONLY place the
            // stale-final latch arms: the slot binding survives the
            // settle, so a straggler final from the old range would land
            // in the follow-on utterance. In the release path the .held
            // guard already drops stragglers, and arming there would only
            // eat the NEXT utterance's genuine final — the re-arm loop
            // that deafened the lane (review round 2).
            if timedOut { staleDropUntilFinal = true }
            settleKeepsSlot = false
            current = Utterance(id: UUID(), openedAt: Date(), lastVoicedNowAt: Date())
            stats.utterancesOpened += 1
            for buffer in laneBuffer { commands.yield(.feed(buffer)) }
            laneBuffer.removeAll()
            laneBufferSeconds = 0
        } else {
            settleKeepsSlot = false
            current = nil
            if slotState == .held {
                commands.yield(.release)
                slotState = .none
            }
            // slotState == .acquiring: the pending acquire is left
            // standing; slotGranted releases immediately if no new
            // utterance opened by then (no squatting on shared slots), or
            // serves the next utterance if one did.
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

    private func pumpMT() {
        guard !mtInFlight, !closed, let job = mtQueue.first else { return }
        mtQueue.removeFirst()
        if translationDead {
            onTranscript?(.translationText(utterance: job.id, text: "", isFinal: true))
            pumpMT()
            return
        }
        mtInFlight = true
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await self.context.translator.translate(job.sourceText, job: job.id)
                self.queue.async { self.mtFinished(job: job, text: translated, started: started, error: nil) }
            } catch {
                self.queue.async { self.mtFinished(job: job, text: nil, started: started, error: error) }
            }
        }
    }

    private func mtFinished(job: TranslationJob, text: String?, started: Date, error: Error?) {
        mtInFlight = false
        guard !closed else { return }
        if let text {
            let seconds = Date().timeIntervalSince(started)
            stats.lastTranslateSeconds = seconds
            stats.utterancesTranslated += 1
            onMetric?(.translationSeconds(seconds))
            onTranscript?(.translationText(utterance: job.id, text: text, isFinal: true))
            enqueueTTS(TTSJob(id: job.id, text: text, speechEndedAt: job.speechEndedAt, submittedAt: Date()))
        } else {
            let description = error?.localizedDescription ?? "unknown"
            stats.lastError = "translate: \(description)"
            Log.error("[\(label)] translation failed: \(description)")
            onTranscript?(.translationText(utterance: job.id, text: "", isFinal: true))
            // A missing pack is stage-fatal but must not kill capture
            // (§8.2): transcription continues, translations show "—".
            // Typed check (TranslationError.notInstalled has a ~= operator
            // over `any Error`) — matching localizedDescription would
            // break on non-English device locales.
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
