import Foundation
import AVFoundation

/// One streamed piece of synthesized speech: 24 kHz mono PCM16 LE audio
/// (EngineGraph's native playback contract) plus at most one cost estimate.
enum TTSChunk {
    case audio(Data)
    case usage(costDollars: Double)
}

/// TTS stage of the staged pipeline: translated text in, playable audio
/// out. Implementations: on-device AVSpeechSynthesizer (default, instant,
/// free) and OpenAI speech (network, more natural voices).
protocol SpeechSynthesisStage: AnyObject {
    /// `languageCode` is the ISO-639-1 target language (what the text is
    /// written in). Calls are serialized per lane by the staged client.
    func synthesize(text: String, languageCode: String) -> AsyncThrowingStream<TTSChunk, Error>
}

/// On-device synthesis via AVSpeechSynthesizer, rendered offline with
/// write(_:toBufferCallback:) — it never touches AVAudioSession, so the
/// audio goes through EngineGraph's per-lane players and ducking exactly
/// like realtime translated audio, instead of fighting the engine for the
/// output route.
final class OnDeviceSynthesizer: NSObject, SpeechSynthesisStage {

    private let synthesizer = AVSpeechSynthesizer()
    /// Explicit per-lane voice pick (AVSpeechSynthesisVoice identifier);
    /// nil = auto-distinct rotation by laneIndex, skipping voices other
    /// lanes explicitly picked.
    private let explicitVoiceIdentifier: String?
    private let laneIndex: Int
    private let excludedVoiceIdentifiers: Set<String>
    private var warnedMissingVoice = false
    private var warnedExplicitFallback = false
    /// One lane synthesizes one target language; resolution can enumerate
    /// the whole installed-voice registry, so resolve once and cache.
    private var cachedVoice: (language: String, voice: AVSpeechSynthesisVoice?)?

    init(explicitVoiceIdentifier: String?, laneIndex: Int, excludedVoiceIdentifiers: Set<String> = []) {
        self.explicitVoiceIdentifier = explicitVoiceIdentifier
        self.laneIndex = laneIndex
        self.excludedVoiceIdentifiers = excludedVoiceIdentifiers
        super.init()
    }

    func synthesize(text: String, languageCode: String) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continuation.finish()
                return
            }
            if cachedVoice?.language != languageCode {
                if let explicitVoiceIdentifier,
                   !Self.explicitVoiceIsUsable(explicitVoiceIdentifier, languageCode: languageCode),
                   !warnedExplicitFallback {
                    warnedExplicitFallback = true
                    Log.warn("[tts] lane voice '\(explicitVoiceIdentifier)' missing or wrong language for '\(languageCode)' — using auto voice")
                }
                cachedVoice = (languageCode, Self.resolveVoice(
                    explicitIdentifier: explicitVoiceIdentifier,
                    laneIndex: laneIndex,
                    languageCode: languageCode,
                    excluding: excludedVoiceIdentifiers
                ))
            }
            guard let voice = cachedVoice?.voice else {
                if !warnedMissingVoice {
                    warnedMissingVoice = true
                    Log.warn("[tts] no on-device voice for '\(languageCode)' — segments degrade to text-only")
                }
                continuation.finish()
                return
            }
            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = voice

            // Rendered buffers arrive in a voice-dependent format; convert
            // each to the 24 kHz PCM16 playback contract. The resampler is
            // built from the first buffer and kept for filter continuity.
            var resampler: StreamResampler?
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // A zero-length buffer is the documented end-of-utterance
                // marker.
                guard pcm.frameLength > 0 else {
                    continuation.finish()
                    return
                }
                if resampler == nil {
                    resampler = StreamResampler(inputFormat: pcm.format)
                    if resampler == nil {
                        Log.warn("[tts] cannot convert synthesizer format \(pcm.format) — dropping segment audio")
                        continuation.finish()
                        return
                    }
                }
                if let data = resampler?.convert(pcm), !data.isEmpty {
                    continuation.yield(.audio(data))
                }
            }
            continuation.onTermination = { [synthesizer] reason in
                // A cancelled segment (lane closing) must stop the render;
                // stopSpeaking also flushes the write callback.
                if case .cancelled = reason {
                    synthesizer.stopSpeaking(at: .immediate)
                }
            }
        }
    }

    // MARK: - Voice resolution (shared with the Settings preview so the
    // preview plays exactly what the lane will use)

    /// The voice a lane speaks `languageCode` (ISO-639-1) with: the explicit
    /// identifier if it exists and matches the language, else the
    /// auto-distinct pick — the lane's slot in the installed-voice rotation,
    /// with other lanes' explicit picks (`excluding`) removed so a pick
    /// can't collide with an auto lane's slot.
    static func resolveVoice(explicitIdentifier: String?, laneIndex: Int,
                             languageCode: String,
                             excluding excluded: Set<String> = []) -> AVSpeechSynthesisVoice? {
        if let explicitIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: explicitIdentifier),
           languageMatches(voice.language, languageCode) {
            return voice
        }
        let roster = installedVoices(for: languageCode)
        let rotation = roster.filter { !excluded.contains($0.identifier) }
        let pool = rotation.isEmpty ? roster : rotation
        if !pool.isEmpty {
            return pool[laneIndex % pool.count]
        }
        return voice(for: languageCode)
    }

    /// Deterministic per-language roster used for both auto-distinct
    /// rotation and the Settings picker (same order, so what you see is
    /// what rotates). Novelty voices ("Bells", "Bad News"…) and Personal
    /// Voice are excluded — they'd otherwise occupy rotation slots.
    static func installedVoices(for languageCode: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { languageMatches($0.language, languageCode) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                return $0.identifier < $1.identifier
            }
    }

    /// Primary-subtag comparison: "zh-CN" matches "zh", "en-GB" matches "en".
    private static func languageMatches(_ voiceLanguage: String, _ languageCode: String) -> Bool {
        let voicePrimary = voiceLanguage.lowercased().split(separator: "-").first ?? ""
        let wantedPrimary = languageCode.lowercased().split(separator: "-").first ?? ""
        return !wantedPrimary.isEmpty && voicePrimary == wantedPrimary
    }

    /// Last-resort fallback when the filtered roster is empty: exact BCP-47
    /// match, then any installed voice sharing the prefix (novelty included
    /// — a strange voice beats silence).
    static func voice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: languageCode) {
            return exact
        }
        let prefix = languageCode.lowercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
        return candidates.max { a, b in
            a.quality.rawValue < b.quality.rawValue
        }
    }

    /// Whether an explicit pick would actually be used (drives the one-shot
    /// fallback warning).
    private static func explicitVoiceIsUsable(_ identifier: String, languageCode: String) -> Bool {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return false }
        return languageMatches(voice.language, languageCode)
    }
}

/// OpenAI TTS over HTTPS. `response_format: "pcm"` returns 24 kHz mono
/// PCM16 LE — byte-for-byte what EngineGraph.schedule(pcm16:) plays.
final class OpenAISynthesizer: SpeechSynthesisStage {

    static let defaultEndpoint = "https://api.openai.com/v1/audio/speech"

    /// Voices accepted by POST /v1/audio/speech, ordered for auto-distinct
    /// lane rotation (also feeds the Settings picker). Verify against the
    /// current docs when touching this — a stale entry fails soft (HTTP 400
    /// → segment logs "TTS failed", translation still displays).
    static let voiceRoster = ["alloy", "echo", "shimmer", "ash", "coral", "sage", "ballad", "fable"]

    private let apiKey: String
    private let model: String
    private let voice: String
    private let endpoint: String

    /// Rough character-based estimate for the cost meter (OpenAI bills TTS
    /// by token; ~$15/1M characters is the conservative published order of
    /// magnitude across the TTS models).
    private static let dollarsPerCharacter = 15.0 / 1_000_000

    /// nil explicitVoice = auto-distinct: the lane's slot in the roster,
    /// skipping voices other lanes explicitly picked so a pick can't
    /// collide with an auto lane. A stored voice that's no longer in the
    /// roster falls back to auto too — matching what the Settings picker
    /// displays (it shows unknown values as Auto).
    init(apiKey: String, model: String, explicitVoice: String?, laneIndex: Int,
         excludedVoices: Set<String> = [],
         endpoint: String = OpenAISynthesizer.defaultEndpoint) {
        self.apiKey = apiKey
        self.model = model
        if let explicitVoice, Self.voiceRoster.contains(explicitVoice) {
            self.voice = explicitVoice
        } else {
            let available = Self.voiceRoster.filter { !excludedVoices.contains($0) }
            let rotation = available.isEmpty ? Self.voiceRoster : available
            self.voice = rotation[laneIndex % rotation.count]
        }
        self.endpoint = endpoint
    }

    func synthesize(text: String, languageCode: String) -> AsyncThrowingStream<TTSChunk, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = makeRequest(text: trimmed)
        return AsyncThrowingStream { continuation in
            guard !trimmed.isEmpty else {
                continuation.finish()
                return
            }
            let task = Task {
                do {
                    guard let request else {
                        throw NSError(domain: "OpenAISynthesizer", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Bad TTS endpoint URL"
                        ])
                    }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw NSError(domain: "OpenAISynthesizer", code: http.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(300))"
                        ])
                    }
                    // Forward in ~100 ms pieces (4800 bytes at 24 kHz PCM16)
                    // so playback starts while the tail still downloads.
                    // Sample alignment matters: only even byte counts leave
                    // the buffer, and flushing swaps in the ≤1-byte
                    // remainder instead of shuffling the buffer down.
                    let chunkBytes = 4800
                    var buffer = [UInt8]()
                    buffer.reserveCapacity(chunkBytes + 1)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= chunkBytes {
                            let evenCount = buffer.count & ~1
                            continuation.yield(.audio(Data(buffer[0..<evenCount])))
                            buffer = evenCount < buffer.count ? [buffer[evenCount]] : []
                            buffer.reserveCapacity(chunkBytes + 1)
                        }
                    }
                    if buffer.count >= 2 {
                        continuation.yield(.audio(Data(buffer[0..<(buffer.count & ~1)])))
                    }
                    continuation.yield(.usage(costDollars: Double(trimmed.count) * Self.dollarsPerCharacter))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(text: String) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        let body: [String: Any] = [
            "model": model,
            "voice": voice,
            "input": text,
            "response_format": "pcm"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
