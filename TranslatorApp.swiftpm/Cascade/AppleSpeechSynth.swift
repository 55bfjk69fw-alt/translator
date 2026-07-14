import Foundation
import AVFoundation

/// Apple TTS provider: voice inventory/ranking/auto-assignment plus the
/// write()-based per-lane synthesizer (docs/CASCADE-PIPELINE.md §6.3/§6.4).
enum AppleTTSProvider {
    static let id = "apple"

    /// Ranking tiers for auto-assignment. The floor exists because a
    /// stock device's inventory is dominated by voices that pass the
    /// novelty/personal filter but should never be auto-assigned: the
    /// eloquence set (Eddy/Flo/Grandma/…) and legacy MacinTalk voices
    /// (Fred, Kathy, …) — probe finding §10.7. They stay selectable in
    /// the picker, grouped last.
    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        if voice.identifier.contains(".eloquence.") { return 0 }
        if voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.") { return 0 }
        switch voice.quality {
        case .premium: return 4
        case .enhanced: return 3
        default:
            return voice.identifier.contains(".super-compact.") ? 2 : 1
        }
    }

    /// Usable voices for a target language (BCP-47 prefix match, e.g.
    /// "en" matches en-US/en-GB), best-ranked first. Re-query on
    /// availableVoicesDidChangeNotification — availability is not stable
    /// (downloads, deletions, storage-pressure purges).
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.hasPrefix(prefix)
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted {
                let (ra, rb) = (rank($0), rank($1))
                return ra != rb ? ra > rb : $0.identifier < $1.identifier
            }
    }

    static var voiceDownloadHint: String {
        "Better voices: Settings → Accessibility → Read & Speak (Spoken Content pre-iOS 26) → Voices → English — enhanced/premium voices make lanes genuinely distinct."
    }

    /// The lane's voice: the persisted choice if it still exists AND
    /// matches the target language, else an auto-assigned distinct
    /// default (persisted so the assignment is stable ever after).
    /// Fewer usable voices than lanes ⇒ the ranked list cycles
    /// (duplicates land on distant channels by index) — best-effort,
    /// never a blocker.
    static func voice(for channel: Int, language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        if let stored = AppSettings.laneVoice(provider: id, language: language, channel: channel),
           let voice = AVSpeechSynthesisVoice(identifier: stored),
           voice.language.hasPrefix(prefix) {
            return voice
        }
        let ranked = voices(for: language)
        guard !ranked.isEmpty else { return nil }
        // Interleave accents for adjacent channels where inventory allows:
        // group by exact language variant and round-robin the groups.
        var byVariant: [String: [AVSpeechSynthesisVoice]] = [:]
        for voice in ranked { byVariant[voice.language, default: []].append(voice) }
        let variants = byVariant.keys.sorted()
        var interleaved: [AVSpeechSynthesisVoice] = []
        var offset = 0
        while interleaved.count < ranked.count {
            for variant in variants {
                if let list = byVariant[variant], offset < list.count {
                    interleaved.append(list[offset])
                }
            }
            offset += 1
        }
        let assigned = interleaved[channel % interleaved.count]
        AppSettings.setLaneVoice(assigned.identifier, provider: id, language: language, channel: channel)
        Log.info("[tts] lane \(channel) auto-assigned voice \(assigned.identifier)")
        return assigned
    }
}

/// One write()-rendering synthesizer per lane. Long-lived for the
/// conversation (a function-local synthesizer can be deallocated
/// mid-render and its callback silently never fires — the iOS 16 bug
/// class). The lane engine submits at most ONE job at a time and owns
/// the queue/backpressure; this class just renders.
///
/// Output contract: 24 kHz mono PCM16 LE chunks via onAudio, then
/// onFinished — the existing playback seam. The synthesizer's native
/// format varies BY VOICE (measured: Tingting = 22.05 kHz float32) and
/// was historically misreported, so the converter is built from the
/// first real buffer of each job, never assumed.
final class AppleSpeechSynth: SpeechSynth {

    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String
    private let rate: Float
    private let label: String
    /// Confines job state; write() callbacks hop here.
    private let queue: DispatchQueue

    var onAudio: ((UUID, Data) -> Void)?
    var onFinished: ((UUID, String?) -> Void)?

    // Queue-confined per-job state.
    private var currentJob: UUID?
    private var converter: AVAudioConverter?
    private var cancelled = false
    /// One-deep hold: write()-while-writing on a single synthesizer was
    /// never probe-validated, so a job arriving while another renders
    /// (e.g. the prewarm racing the first real utterance) waits here and
    /// starts on the sentinel buffer of the previous one. The lane engine
    /// itself never submits two real jobs concurrently.
    private var pendingJob: (text: String, job: UUID, deliver: Bool)?
    private let languageHint: String

    init(lane: Int, voiceIdentifier: String, rate: Double, languageHint: String) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        self.label = "tts ch\(lane)"
        self.languageHint = languageHint
        self.queue = DispatchQueue(label: "translator.cascade.tts.\(lane)")
    }

    /// Render one short throwaway utterance to absorb the seconds-scale
    /// first-use voice rule-loading off the critical path (§6.3 warm-up).
    func prewarm() {
        synthesize(text: " Ready.", job: UUID(), deliver: false)
    }

    func synthesize(text: String, job: UUID) {
        synthesize(text: text, job: job, deliver: true)
    }

    private func synthesize(text: String, job: UUID, deliver: Bool) {
        queue.async {
            guard !self.cancelled else { return }
            if self.currentJob != nil {
                self.pendingJob = (text, job, deliver)
                return
            }
            self.beginRender(text: text, job: job, deliver: deliver)
        }
    }

    /// Queue-confined.
    private func beginRender(text: String, job: UUID, deliver: Bool) {
        currentJob = job
        converter = nil
        let utterance = AVSpeechUtterance(string: text)
        // Fall back to a TARGET-LANGUAGE voice, never the device-locale
        // default (a Chinese system voice reading English is worse than
        // any English compact voice).
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: languageHint)
            ?? AVSpeechSynthesisVoice(language: nil)
        utterance.rate = rate
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            self.queue.async { self.handleBuffer(buffer, job: job, deliver: deliver) }
        }
    }

    /// Queue-confined. Zero-length buffer = completion (the community-
    /// established write() contract; the didFinish delegate is unreliable
    /// with write()).
    private func handleBuffer(_ buffer: AVAudioBuffer, job: UUID, deliver: Bool) {
        guard job == currentJob, !cancelled else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            currentJob = nil
            if deliver { onFinished?(job, nil) }
            if let pending = pendingJob {
                pendingJob = nil
                beginRender(text: pending.text, job: pending.job, deliver: pending.deliver)
            }
            return
        }
        guard deliver else { return }
        if converter == nil {
            converter = AVAudioConverter(from: pcm.format, to: StreamResampler.targetFormat)
            if converter == nil {
                Log.error("[\(label)] no converter for voice format \(Int(pcm.format.sampleRate)) Hz — dropping this utterance's audio")
            }
        }
        guard let converter, let data = Self.convertToPCM16(pcm, converter: converter) else { return }
        onAudio?(job, data)
    }

    func cancelAll() {
        queue.async {
            self.cancelled = true
            self.currentJob = nil
            self.pendingJob = nil
            self.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Convert one voice-native buffer to 24 kHz mono PCM16 LE bytes.
    private static func convertToPCM16(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
        let ratio = StreamResampler.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: StreamResampler.targetFormat, frameCapacity: capacity) else {
            return nil
        }
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
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else {
            if let error { Log.warn("[tts] convert failed: \(error.localizedDescription)") }
            return nil
        }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
