import Foundation
import AVFoundation
import Speech
import Translation
import UIKit

/// CP0 hardware probe for the cascade pipeline (docs/CASCADE-PIPELINE.md §10).
///
/// Every claim the design marked UNVERIFIED gets exercised here, on the
/// actual iPad, before any pipeline code is built against it:
///  1. The iOS 26 frameworks work inside a Swift Playgrounds app playground
///     at all (this file compiling and running IS the test), including a
///     headless TranslationSession and its `.notInstalled` behavior.
///  2. How many concurrent zh SpeechAnalyzers the device admits
///     (all-at-once creation, the eager-open shape) before
///     `insufficientResources`.
///  3. Whether two `AVSpeechSynthesizer.write()` renders run concurrently
///     or serialize.
///  4. Whether SpeechTranscriber emits Chinese punctuation (。！？).
///  5. On-device translation latency per sentence (serial + batch).
///  6. STT finalize latency with/without `prepareToAnalyze`.
///  7. The device's voice inventory and each voice's actual write() format.
///  8. Sustained-load thermals/battery over a configurable run.
///  9. What the zh model emits for sustained ENGLISH audio — Latin text
///     (the script gate's F1 case) or phonetic Han (F2) — and whether
///     per-run `transcriptionConfidence` separates F2 gibberish from a
///     genuine-Mandarin baseline (docs/ENGLISH-SUPPRESSION.md §5).
///
/// No microphone, no network (except asset/pack downloads), no API key:
/// Mandarin test audio is synthesized on-device with a zh voice and fed
/// straight to the transcribers — a self-contained TTS→STT→MT loop.
///
/// Like the dual-input probe, results are appended to a shareable log and
/// belong in docs/CASCADE-PIPELINE.md §10 once run. Where Apple's iOS 26
/// API surface differs from this code (it was written against docs, not a
/// compiler), fix signatures here from compiler evidence — every iOS 26
/// speech/translation call in the app lives in this file on purpose.
@MainActor
final class CascadeProbe: ObservableObject {

    @Published private(set) var running = false
    @Published private(set) var stage: String?
    @Published private(set) var lines: [String] = []
    /// Download state for the STT model row (translation packs download
    /// through the SwiftUI sheet in CascadeProbeSection instead).
    @Published private(set) var sttDownloadStatus: String?
    @Published var sustainedMinutes = 10

    private var probeTask: Task<Void, Never>?

    // The language pair the design targets. zh-Hans for Translation,
    // zh_CN-equivalent locale for SpeechTranscriber.
    private let sourceLanguage = Locale.Language(identifier: "zh-Hans")
    private let targetLanguage = Locale.Language(identifier: "en")
    private let sourceLocale = Locale(identifier: "zh_CN")

    /// Scripted Mandarin covering statements, a question, and an
    /// exclamation, so probe item 4 can look for 。？！ in the finals.
    private let mandarinSentences = [
        "今天的天气非常好。",
        "你吃过晚饭了吗？",
        "这个菜太好吃了！",
        "我们明天上午十点在公司门口见面。",
        "他昨天买了一台新的电脑。"
    ]

    /// Sustained English for step 9 — plain conversational sentences, the
    /// register the mics actually pick up when the user speaks.
    private let englishSentences = [
        "Could you tell me how much this costs?",
        "I think we should meet tomorrow morning instead.",
        "The weather has been really nice this week.",
        "Please let me know when the documents are ready.",
        "We are planning to visit the factory next month."
    ]

    // MARK: - Control

    func runAll() {
        // Keyed on probeTask, not `running`: a cancelled run keeps
        // executing until its next checkpoint, and starting a second run
        // over it would interleave logs and share the render synths.
        guard probeTask == nil else { return }
        running = true
        lines.removeAll()
        probeTask = Task { [weak self] in
            await self?.runAllSteps()
            await MainActor.run {
                self?.running = false
                self?.stage = nil
                self?.probeTask = nil
            }
        }
    }

    func runSustained() {
        guard probeTask == nil else { return }
        running = true
        probeTask = Task { [weak self] in
            await self?.sustainedLoad()
            await MainActor.run {
                self?.running = false
                self?.stage = nil
                self?.probeTask = nil
            }
        }
    }

    /// Requests cancellation; `running` stays true until the task reaches
    /// its next checkpoint and unwinds (the completion above resets it) —
    /// so a new run can't start while the old one is still winding down.
    func cancel() {
        probeTask?.cancel()
        log("Probe cancel requested — stopping at the next checkpoint")
    }

    func exportText() -> String {
        (["Cascade probe — \(Date().formatted(.iso8601))",
          "Device: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"]
         + lines).joined(separator: "\n")
    }

    /// Download the zh speech model through AssetInventory (programmatic,
    /// no system sheet — the mechanism the setup card will use).
    func downloadSTTAssets() {
        Task { [weak self] in
            guard let self else { return }
            self.sttDownloadStatus = "checking…"
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: self.sourceLocale) else {
                    self.sttDownloadStatus = "zh not supported on this device"
                    return
                }
                let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    self.sttDownloadStatus = "downloading…"
                    try await request.downloadAndInstall()
                    self.sttDownloadStatus = "installed"
                    self.log("STT assets for \(locale.identifier) downloaded and installed")
                } else {
                    self.sttDownloadStatus = "already installed"
                    self.log("STT assets for \(locale.identifier) already installed")
                }
            } catch {
                self.sttDownloadStatus = "failed: \(error.localizedDescription)"
                self.log("STT asset download FAILED: \(describe(error))")
            }
        }
    }

    // MARK: - The run

    private func runAllSteps() async {
        log("=== Cascade probe start ===")
        await step1Frameworks()
        guard !Task.isCancelled else { return }
        let rendered = await step2RenderMandarin()
        guard !Task.isCancelled else { return }
        var finals: [String] = []
        if let rendered {
            finals = await step3ConcurrentAnalyzers(rendered: rendered)
            guard !Task.isCancelled else { return }
            step4Punctuation(finals: finals)
            await step6FinalizeLatency(rendered: rendered)
        } else {
            log("[2-4,6] SKIPPED — no Mandarin voice available to synthesize test audio (download a Chinese voice in Settings → Accessibility → Read & Speak → Voices)")
        }
        guard !Task.isCancelled else { return }
        await step5TranslationLatency(sentences: finals.isEmpty ? mandarinSentences : finals)
        guard !Task.isCancelled else { return }
        await step3bConcurrentWrite()
        guard !Task.isCancelled else { return }
        step7VoiceInventory()
        guard !Task.isCancelled else { return }
        await step9EnglishIntoZh(mandarin: rendered)
        log("=== Cascade probe done — Share the log and paste results into docs/CASCADE-PIPELINE.md §10 ===")
    }

    // MARK: - Step 1: frameworks present & headless translation

    private func step1Frameworks() async {
        setStage("1/7 framework availability")
        // Speech: locale support. Reaching this line at all means `import
        // Speech`'s iOS 26 surface linked inside the app playground.
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let zh = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale)
        log("[1] SpeechTranscriber: \(supported.count) supported locales; zh match: \(zh?.identifier ?? "NONE"); installed: \(installed.map(\.identifier).sorted().joined(separator: ", "))")

        // Translation: pack status + headless session behavior.
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        log("[1] Translation zh-Hans→en pack status: \(describeStatus(status))")
        // The design (§2.1) says the headless init is non-throwing and a
        // pack-less session errors with .notInstalled at translate() time —
        // verify exactly that, whichever state the device is in.
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        do {
            let response = try await session.translate("你好")
            log("[1] Headless TranslationSession works: 你好 → \(response.targetText)")
        } catch {
            log("[1] Headless translate threw: \(describe(error)) — expected .notInstalled if the pack status above is not installed")
        }

        // TTS: enumeration works.
        let voices = AVSpeechSynthesisVoice.speechVoices()
        log("[1] AVSpeechSynthesisVoice inventory: \(voices.count) voices installed")
    }

    // MARK: - Step 2: synthesize Mandarin test audio

    private struct RenderedAudio {
        let buffers: [AVAudioPCMBuffer]
        let format: AVAudioFormat
        /// One entry per sentence: the buffer index range it occupies, so
        /// steps can feed sentence-by-sentence.
        let sentenceRanges: [Range<Int>]
    }

    /// Long-lived synthesizers (a function-local one can be deallocated
    /// mid-render and its callback silently never fires — the iOS 16 bug
    /// class the research flagged). LAZY: this object is constructed with
    /// the Diagnostics tab, and idle synthesizers must not touch the
    /// audio system at app launch — they exist only once a probe runs.
    private lazy var renderSynth = AVSpeechSynthesizer()
    private lazy var concurrencySynthA = AVSpeechSynthesizer()
    private lazy var concurrencySynthB = AVSpeechSynthesizer()

    private func step2RenderMandarin() async -> RenderedAudio? {
        setStage("2/7 synthesizing Mandarin test audio")
        guard let zhVoice = bestVoice(languagePrefix: "zh-CN") ?? bestVoice(languagePrefix: "zh") else {
            log("[2] No zh voice installed — cannot synthesize test audio")
            return nil
        }
        log("[2] Rendering \(mandarinSentences.count) sentences with \(zhVoice.identifier)")
        var all: [AVAudioPCMBuffer] = []
        var ranges: [Range<Int>] = []
        var format: AVAudioFormat?
        for sentence in mandarinSentences {
            let result = await render(text: sentence, voice: zhVoice, synthesizer: renderSynth, timeout: 30)
            guard case .finished(let buffers, let bufferFormat) = result, let bufferFormat else {
                log("[2] Render FAILED for “\(sentence)”: \(result.failureDescription) — write() may be broken in this environment")
                return nil
            }
            if format == nil {
                format = bufferFormat
                log("[2] write() buffer format for \(zhVoice.identifier): \(describeFormat(bufferFormat))")
            }
            let start = all.count
            all.append(contentsOf: buffers)
            ranges.append(start..<all.count)
        }
        guard let format else { return nil }
        let frames = all.reduce(0) { $0 + Int($1.frameLength) }
        log("[2] Rendered \(all.count) buffers, \(String(format: "%.1f", Double(frames) / format.sampleRate)) s of audio")
        return RenderedAudio(buffers: all, format: format, sentenceRanges: ranges)
    }

    // MARK: - Step 3: concurrent analyzers (THE gating measurement)

    private func step3ConcurrentAnalyzers(rendered: RenderedAudio) async -> [String] {
        setStage("3/7 concurrent zh analyzers")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale) else {
            log("[3] zh locale unsupported — skipped")
            return []
        }
        var finalsFromSingle: [String] = []
        for n in 1...4 {
            guard !Task.isCancelled else { return finalsFromSingle }
            let started = Date()
            do {
                // All-at-once creation: the eager-open-at-Start shape the
                // design commits to (§6.1). Every lane gets an identical
                // config so engine sharing gets its best chance.
                var lanes: [(SpeechTranscriber, SpeechAnalyzer)] = []
                for _ in 0..<n {
                    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    lanes.append((transcriber, analyzer))
                }
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [lanes[0].0]) else {
                    log("[3] bestAvailableAudioFormat returned nil — assets missing? (use “Download STT model” first)")
                    return finalsFromSingle
                }
                if n == 1 { log("[3] Analyzer format: \(describeFormat(analyzerFormat))") }
                let finals = try await withThrowingTaskGroup(of: [String].self) { group in
                    for (transcriber, analyzer) in lanes {
                        group.addTask { [rendered] in
                            try await Self.transcribeOnce(
                                rendered: rendered,
                                transcriber: transcriber,
                                analyzer: analyzer,
                                analyzerFormat: analyzerFormat
                            )
                        }
                    }
                    var results: [[String]] = []
                    for try await finals in group { results.append(finals) }
                    return results
                }
                let elapsed = Date().timeIntervalSince(started)
                let counts = finals.map { "\($0.count)" }.joined(separator: "/")
                log("[3] n=\(n): OK in \(String(format: "%.1f", elapsed)) s — finals per lane: \(counts)")
                if n == 1, let first = finals.first { finalsFromSingle = first }
            } catch {
                log("[3] n=\(n): FAILED after \(String(format: "%.1f", Date().timeIntervalSince(started))) s — \(describe(error))")
                log("[3] → admission limit ≈ \(n - 1). Per the design, a limit below the enabled lane count reroutes CP2 through the pooled-mode design pass.")
                break
            }
        }
        return finalsFromSingle
    }

    /// One full transcription pass: feed all rendered audio (converted to
    /// the analyzer format), end input, finalize, return final texts.
    /// nonisolated static so concurrent lanes don't serialize on the main
    /// actor.
    private nonisolated static func transcribeOnce(
        rendered: RenderedAudio,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat
    ) async throws -> [String] {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        // Harvest results concurrently — the sequence ends when analysis
        // finishes.
        let harvest = Task<[String], Error> {
            var finals: [String] = []
            for try await result in transcriber.results where result.isFinal {
                finals.append(String(result.text.characters))
            }
            return finals
        }
        // Any throw below must cancel the harvest task: it iterates a
        // results sequence that only ends when the analyzer finishes, so a
        // leaked harvest keeps its transcriber alive — which in step 3
        // would contaminate the admission-limit measurement of the NEXT
        // run with lanes leaked from this one.
        do {
            try await analyzer.start(inputSequence: stream)
            guard let converter = AVAudioConverter(from: rendered.format, to: analyzerFormat) else {
                throw NSError(domain: "CascadeProbe", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No converter \(rendered.format.sampleRate) Hz → \(analyzerFormat.sampleRate) Hz"
                ])
            }
            // Deliberately unpaced (a burst): step 3 measures admission
            // and throughput. The finalize-latency measurement uses the
            // paced feed in step 6 instead.
            for buffer in rendered.buffers {
                if let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            continuation.finish()
            // Terminating the input sequence does NOT finish the session —
            // the doc-verbatim gotcha. Finish explicitly and wait for the
            // results sequence to drain.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            harvest.cancel()
            throw error
        }
        return try await harvest.value
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
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

    // MARK: - Step 3b: concurrent write()

    private func step3bConcurrentWrite() async {
        setStage("3b/7 concurrent write() renders")
        // The fallback must exclude voiceA: a bare "en" prefix matches
        // en-US too and would typically re-select the same voice — and two
        // synths sharing one voice could serialize on shared voice
        // resources and mislabel the device as "renders SERIALIZED".
        guard let voiceA = bestVoice(languagePrefix: "en-US"),
              let voiceB = bestVoice(languagePrefix: "en-GB")
                ?? bestVoice(languagePrefix: "en", excluding: voiceA.identifier) else {
            log("[3b] Need two distinct English voices — skipped")
            return
        }
        let text = "The quick brown fox jumps over the lazy dog, then pauses to admire the view across the valley."
        // Serial baseline (also warms both voices so the concurrent pass
        // isn't measuring rule loading).
        let serialStart = Date()
        let a1 = await render(text: text, voice: voiceA, synthesizer: concurrencySynthA, timeout: 30)
        let b1 = await render(text: text, voice: voiceB, synthesizer: concurrencySynthB, timeout: 30)
        let serialSeconds = Date().timeIntervalSince(serialStart)
        guard case .finished = a1, case .finished = b1 else {
            log("[3b] Serial renders failed (A: \(a1.failureDescription), B: \(b1.failureDescription)) — cannot test concurrency")
            return
        }
        // Concurrent pass: two different synthesizer instances, two voices.
        let concurrentStart = Date()
        async let a2 = render(text: text, voice: voiceA, synthesizer: concurrencySynthA, timeout: 30)
        async let b2 = render(text: text, voice: voiceB, synthesizer: concurrencySynthB, timeout: 30)
        let (resultA, resultB) = await (a2, b2)
        let concurrentSeconds = Date().timeIntervalSince(concurrentStart)
        switch (resultA, resultB) {
        case (.finished(let buffersA, _), .finished(let buffersB, _)):
            let verdict = concurrentSeconds < serialSeconds * 0.75
                ? "renders OVERLAP — per-lane synths can render in parallel"
                : "renders appear SERIALIZED — enable the shared render queue fallback (design §6.3)"
            log("[3b] Serial \(String(format: "%.2f", serialSeconds)) s vs concurrent \(String(format: "%.2f", concurrentSeconds)) s (\(buffersA.count)/\(buffersB.count) buffers) → \(verdict)")
        default:
            log("[3b] Concurrent render FAILED (A: \(resultA.failureDescription), B: \(resultB.failureDescription)) — write() cannot run concurrently here; use the shared render queue fallback")
        }
    }

    // MARK: - Step 4: Chinese punctuation

    private func step4Punctuation(finals: [String]) {
        setStage("4/7 zh punctuation")
        guard !finals.isEmpty else {
            log("[4] No finals from step 3 — skipped")
            return
        }
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        let joined = finals.joined(separator: " ")
        let found = joined.filter { enders.contains($0) }
        if found.isEmpty {
            log("[4] NO sentence punctuation in finals — the cascade must rely on VAD boundaries + the 12 s hard split alone (design already allows this); finals: \(joined)")
        } else {
            log("[4] Punctuation present (\(String(found))) — the 400 ms fast-close tier is usable; finals: \(joined)")
        }
    }

    // MARK: - Step 5: translation latency

    private func step5TranslationLatency(sentences: [String]) async {
        setStage("5/7 translation latency")
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        guard case .installed = status else {
            log("[5] Translation pack not installed (\(describeStatus(status))) — download it first (button above), skipped")
            return
        }
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        // Repeat the pool to get ~20 measurements.
        var pool = sentences
        while pool.count < 20 { pool += sentences }
        pool = Array(pool.prefix(20))
        var timings: [Double] = []
        do {
            for (index, sentence) in pool.enumerated() {
                let start = Date()
                let response = try await session.translate(sentence)
                timings.append(Date().timeIntervalSince(start))
                if index == 0 {
                    log("[5] First translation (cold): “\(sentence)” → “\(response.targetText)” in \(String(format: "%.0f", timings[0] * 1000)) ms")
                }
            }
            let sorted = timings.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            log("[5] Serial: p50 \(String(format: "%.0f", p50 * 1000)) ms, p95 \(String(format: "%.0f", p95 * 1000)) ms over \(timings.count) sentences")
        } catch {
            log("[5] translate() threw mid-run: \(describe(error))")
            return
        }
        // Batch comparison.
        do {
            let requests = pool.map { TranslationSession.Request(sourceText: $0) }
            let start = Date()
            let responses = try await session.translations(from: requests)
            let elapsed = Date().timeIntervalSince(start)
            log("[5] Batch translations(from:): \(responses.count) sentences in \(String(format: "%.0f", elapsed * 1000)) ms total (\(String(format: "%.0f", elapsed * 1000 / Double(responses.count))) ms/sentence)")
        } catch {
            log("[5] Batch translate threw: \(describe(error))")
        }
    }

    // MARK: - Step 6: finalize latency, with/without pre-warm

    private func step6FinalizeLatency(rendered: RenderedAudio) async {
        setStage("6/7 finalize latency")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale) else { return }
        for prewarm in [false, true] {
            guard !Task.isCancelled else { return }
            var timings: [Double] = []
            do {
                for range in rendered.sentenceRanges {
                    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
                    if prewarm {
                        try await analyzer.prepareToAnalyze(in: format)
                    }
                    let sentence = RenderedAudio(
                        buffers: Array(rendered.buffers[range]),
                        format: rendered.format,
                        sentenceRanges: [0..<range.count]
                    )
                    timings.append(try await Self.pacedFinalizeSeconds(
                        sentence: sentence,
                        transcriber: transcriber,
                        analyzer: analyzer,
                        analyzerFormat: format
                    ))
                }
                let sorted = timings.sorted()
                let p50 = sorted[sorted.count / 2]
                log("[6] Finalize latency \(prewarm ? "WITH" : "without") prepareToAnalyze: p50 \(String(format: "%.2f", p50)) s, range \(String(format: "%.2f–%.2f", sorted.first ?? 0, sorted.last ?? 0)) s over \(timings.count) sentences")
            } catch {
                log("[6] FAILED (\(prewarm ? "with" : "without") pre-warm): \(describe(error))")
            }
        }
    }

    /// One paced finalize-latency measurement: feed the sentence at REAL
    /// TIME (sleeping each buffer's duration) so the model keeps up during
    /// "speech" exactly as it would live, then measure last-audio →
    /// final-text. An unpaced burst would measure "process the whole
    /// backlogged utterance + finalize" — a different, larger number that
    /// would mis-tune the design's debounce constants — and would hide the
    /// cold-start model load inside the no-pre-warm case.
    private nonisolated static func pacedFinalizeSeconds(
        sentence: RenderedAudio,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat
    ) async throws -> Double {
        let harvest = Task<[String], Error> {
            var finals: [String] = []
            for try await result in transcriber.results where result.isFinal {
                finals.append(String(result.text.characters))
            }
            return finals
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let audioDone: Date
        do {
            try await analyzer.start(inputSequence: stream)
            guard let converter = AVAudioConverter(from: sentence.format, to: analyzerFormat) else {
                throw NSError(domain: "CascadeProbe", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "No converter for finalize measurement"
                ])
            }
            for buffer in sentence.buffers {
                if let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                let seconds = Double(buffer.frameLength) / sentence.format.sampleRate
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            audioDone = Date()
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            harvest.cancel()
            throw error
        }
        _ = try await harvest.value
        return Date().timeIntervalSince(audioDone)
    }

    // MARK: - Step 7: voice inventory

    private func step7VoiceInventory() {
        setStage("7/7 voice inventory")
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let usable = voices.filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let en = usable.filter { $0.language.hasPrefix("en") }
        let zh = usable.filter { $0.language.hasPrefix("zh") }
        log("[7] \(voices.count) voices (\(usable.count) usable after filtering novelty/personal); \(en.count) English, \(zh.count) Chinese")
        for voice in (en + zh).sorted(by: { $0.identifier < $1.identifier }) {
            log("[7]   \(voice.identifier) — \(voice.name), \(voice.language), \(qualityName(voice.quality))")
        }
        if en.count < 4 {
            log("[7] Fewer than 4 usable English voices — lanes will share voices until more are downloaded (Settings → Accessibility → Read & Speak → Voices)")
        }
    }

    // MARK: - Step 9: English audio into a zh analyzer (script gate + confidence)

    /// docs/ENGLISH-SUPPRESSION.md §5: two questions, one run. (a) Does
    /// the zh-Hans model emit Latin text for sustained English (F1 — the
    /// script gate catches it) or phonetic Han (F2 — it can't)? (b) Do F2
    /// finals carry separably lower `transcriptionConfidence` than a
    /// genuine-Mandarin baseline, i.e. is the layer-2 confidence floor
    /// worth building? Sentence-per-analyzer, matching the pipeline's
    /// per-utterance slots.
    private func step9EnglishIntoZh(mandarin: RenderedAudio?) async {
        setStage("9 English audio → zh analyzer")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale) else {
            log("[9] zh locale unsupported — skipped")
            return
        }
        guard let enVoice = bestVoice(languagePrefix: "en") else {
            log("[9] No English voice installed — skipped")
            return
        }
        log("[9] Rendering \(englishSentences.count) English sentences with \(enVoice.identifier)")
        var buffers: [AVAudioPCMBuffer] = []
        var ranges: [Range<Int>] = []
        var format: AVAudioFormat?
        for sentence in englishSentences {
            let result = await render(text: sentence, voice: enVoice, synthesizer: renderSynth, timeout: 30)
            guard case .finished(let rendered, let bufferFormat) = result, let bufferFormat else {
                log("[9] English render FAILED for “\(sentence)”: \(result.failureDescription) — skipped")
                return
            }
            if format == nil { format = bufferFormat }
            let start = buffers.count
            buffers.append(contentsOf: rendered)
            ranges.append(start..<buffers.count)
        }
        guard let englishFormat = format else { return }
        let english = RenderedAudio(buffers: buffers, format: englishFormat, sentenceRanges: ranges)
        await confidencePass(label: "English", audio: english, expected: englishSentences, locale: locale)
        if let mandarin {
            await confidencePass(label: "Mandarin", audio: mandarin, expected: mandarinSentences, locale: locale)
        } else {
            log("[9] No Mandarin render from step 2 — confidence baseline skipped")
        }
        log("[9] Decision rule (docs/ENGLISH-SUPPRESSION.md §4.2): build the confidence floor only if English-audio finals score clearly below every Mandarin final; ABSENT confidences mean the attribute isn't populated on-device and layer 2 is off the table.")
    }

    /// One confidence-enabled transcription per sentence; logs the final
    /// text, what the lane's script gate would do with it, and the
    /// per-run confidence distribution.
    private func confidencePass(label: String, audio: RenderedAudio, expected: [String], locale: Locale) async {
        for (index, range) in audio.sentenceRanges.enumerated() {
            guard !Task.isCancelled else { return }
            do {
                // Explicit init: the only way to opt into confidence
                // attributes — the `.progressiveTranscription` preset the
                // pipeline uses does not request them.
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: [.transcriptionConfidence]
                )
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    log("[9] bestAvailableAudioFormat returned nil — assets missing?")
                    return
                }
                let sentence = RenderedAudio(
                    buffers: Array(audio.buffers[range]),
                    format: audio.format,
                    sentenceRanges: [0..<range.count]
                )
                let finals = try await Self.transcribeOnceWithConfidence(
                    rendered: sentence,
                    transcriber: transcriber,
                    analyzer: analyzer,
                    analyzerFormat: analyzerFormat
                )
                let spoken = expected.indices.contains(index) ? expected[index] : "?"
                if finals.isEmpty {
                    log("[9] \(label) #\(index + 1) (“\(spoken)”): NO finals")
                }
                for final in finals {
                    let verdict = CascadeLaneEngine.isPredominantlyLatin(final.text)
                        ? "LATIN → gate suppresses" : "HAN → gate passes"
                    log("[9] \(label) #\(index + 1) (“\(spoken)”): “\(final.text)” — \(verdict); confidence \(final.confidenceText)")
                }
            } catch {
                log("[9] \(label) #\(index + 1) FAILED: \(describe(error))")
            }
        }
    }

    private struct ConfidentFinal {
        let text: String
        let confidences: [Double]

        var confidenceText: String {
            guard !confidences.isEmpty else {
                return "ABSENT — no run carried the attribute"
            }
            let mean = confidences.reduce(0, +) / Double(confidences.count)
            return String(format: "mean %.2f, min %.2f over %d run(s)",
                          mean, confidences.min() ?? 0, confidences.count)
        }
    }

    /// transcribeOnce, but keeping per-run `transcriptionConfidence`
    /// alongside each final's text. The attribute reads per the docs'
    /// run-attribute pattern (`audioTimeRange` reads as
    /// `run.audioTimeRange`); if the compiler disagrees with the exact
    /// name, fix it here from compiler evidence — this file's charter.
    private nonisolated static func transcribeOnceWithConfidence(
        rendered: RenderedAudio,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat
    ) async throws -> [ConfidentFinal] {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let harvest = Task<[ConfidentFinal], Error> {
            var finals: [ConfidentFinal] = []
            for try await result in transcriber.results where result.isFinal {
                var confidences: [Double] = []
                for run in result.text.runs {
                    if let confidence = run.transcriptionConfidence {
                        confidences.append(Double(confidence))
                    }
                }
                finals.append(ConfidentFinal(
                    text: String(result.text.characters),
                    confidences: confidences
                ))
            }
            return finals
        }
        // Same throw discipline as transcribeOnce: a leaked harvest keeps
        // its transcriber alive past the step.
        do {
            try await analyzer.start(inputSequence: stream)
            guard let converter = AVAudioConverter(from: rendered.format, to: analyzerFormat) else {
                throw NSError(domain: "CascadeProbe", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "No converter \(rendered.format.sampleRate) Hz → \(analyzerFormat.sampleRate) Hz"
                ])
            }
            for buffer in rendered.buffers {
                if let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            harvest.cancel()
            throw error
        }
        return try await harvest.value
    }

    // MARK: - Step 8: sustained load

    private func sustainedLoad() async {
        setStage("sustained load (\(sustainedMinutes) min)")
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer { UIDevice.current.isBatteryMonitoringEnabled = false }
        let startBattery = batteryText()
        let deadline = Date().addingTimeInterval(Double(sustainedMinutes) * 60)
        log("[8] Sustained run: TTS→STT→MT loop ×2 lanes until \(deadline.formatted(date: .omitted, time: .standard)); battery \(startBattery)")
        guard let rendered = await step2RenderMandarin() else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale) else { return }
        var cycles = 0
        var lastReport = Date()
        while Date() < deadline, !Task.isCancelled {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<2 {
                        group.addTask { [rendered] in
                            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                            let analyzer = SpeechAnalyzer(modules: [transcriber])
                            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
                            _ = try await Self.transcribeOnce(rendered: rendered, transcriber: transcriber, analyzer: analyzer, analyzerFormat: format)
                        }
                    }
                    try await group.waitForAll()
                }
                let availability = LanguageAvailability()
                if case .installed = await availability.status(from: sourceLanguage, to: targetLanguage) {
                    let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
                    for sentence in mandarinSentences {
                        _ = try? await session.translate(sentence)
                    }
                }
                cycles += 1
            } catch {
                log("[8] Cycle \(cycles) failed: \(describe(error)) — continuing")
            }
            if Date().timeIntervalSince(lastReport) > 30 {
                lastReport = Date()
                log("[8] \(cycles) cycles; thermal \(thermalName(ProcessInfo.processInfo.thermalState)); battery \(batteryText())")
            }
        }
        log("[8] Done: \(cycles) cycles; battery \(startBattery) → \(batteryText()); final thermal \(thermalName(ProcessInfo.processInfo.thermalState))")
    }

    /// Battery level as text; UIDevice reports -1.0 when unknown (e.g.
    /// monitoring races), which must not render as "-100%".
    private func batteryText() -> String {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "unknown" : "\(Int(level * 100))%"
    }

    // MARK: - write() rendering (polling, not continuation: a callback that
    // never fires — the documented failure mode — must produce evidence,
    // not a hang)

    private enum RenderResult {
        case finished(buffers: [AVAudioPCMBuffer], format: AVAudioFormat?)
        case timedOut(partialBuffers: Int)

        var failureDescription: String {
            switch self {
            case .finished: return "ok"
            case .timedOut(let count): return "TIMED OUT with \(count) partial buffers (write() callback never completed)"
            }
        }
    }

    private final class RenderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        private var format: AVAudioFormat?
        private var done = false

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            if buffer.frameLength == 0 {
                done = true
            } else {
                if format == nil { format = buffer.format }
                buffers.append(buffer)
            }
        }

        func snapshot() -> (buffers: [AVAudioPCMBuffer], format: AVAudioFormat?, done: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (buffers, format, done)
        }
    }

    private nonisolated func render(
        text: String,
        voice: AVSpeechSynthesisVoice,
        synthesizer: AVSpeechSynthesizer,
        timeout: TimeInterval
    ) async -> RenderResult {
        let box = RenderBox()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            box.append(pcm)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = box.snapshot()
            if state.done {
                return .finished(buffers: state.buffers, format: state.format)
            }
            // Cancelled sleeps return immediately — break instead of
            // busy-spinning out the rest of the timeout.
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let state = box.snapshot()
        return .timedOut(partialBuffers: state.buffers.count)
    }

    // MARK: - Helpers

    private func bestVoice(languagePrefix: String, excluding: String? = nil) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.hasPrefix(languagePrefix)
                    && $0.identifier != excluding
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .max { rank($0.quality) < rank($1.quality) }
    }

    private func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "unknown"
        }
    }

    private func describeStatus(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "installed"
        case .supported: return "supported, needs download"
        case .unsupported: return "UNSUPPORTED"
        @unknown default: return "unknown"
        }
    }

    private nonisolated func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(error.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    private func describeFormat(_ format: AVAudioFormat) -> String {
        let kind: String
        switch format.commonFormat {
        case .pcmFormatFloat32: kind = "float32"
        case .pcmFormatInt16: kind = "int16"
        case .pcmFormatInt32: kind = "int32"
        case .pcmFormatFloat64: kind = "float64"
        default: kind = "other(\(format.commonFormat.rawValue))"
        }
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(kind)\(format.isInterleaved ? ", interleaved" : "")"
    }

    private func setStage(_ name: String) {
        stage = name
        log("--- \(name) ---")
    }

    private func log(_ message: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        lines.append("[\(stamp)] \(message)")
        Log.info("[cascade-probe] \(message)")
    }
}
