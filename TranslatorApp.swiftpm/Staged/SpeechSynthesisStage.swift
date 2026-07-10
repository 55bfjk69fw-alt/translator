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
    private var warnedMissingVoice = false
    /// One lane synthesizes one target language; the prefix-match fallback
    /// enumerates the whole installed-voice registry, so resolve once.
    private var cachedVoice: (language: String, voice: AVSpeechSynthesisVoice?)?

    func synthesize(text: String, languageCode: String) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continuation.finish()
                return
            }
            if cachedVoice?.language != languageCode {
                cachedVoice = (languageCode, Self.voice(for: languageCode))
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

    /// Best on-device voice for a target language given as ISO-639-1
    /// ("en", "zh"): exact BCP-47 match first, then any installed voice
    /// whose language shares the prefix, preferring higher quality.
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
}

/// OpenAI TTS over HTTPS. `response_format: "pcm"` returns 24 kHz mono
/// PCM16 LE — byte-for-byte what EngineGraph.schedule(pcm16:) plays.
final class OpenAISynthesizer: SpeechSynthesisStage {

    static let defaultEndpoint = "https://api.openai.com/v1/audio/speech"

    private let apiKey: String
    private let model: String
    private let voice: String
    private let endpoint: String

    /// Rough character-based estimate for the cost meter (OpenAI bills TTS
    /// by token; ~$15/1M characters is the conservative published order of
    /// magnitude across the TTS models).
    private static let dollarsPerCharacter = 15.0 / 1_000_000

    init(apiKey: String, model: String, voice: String, endpoint: String = OpenAISynthesizer.defaultEndpoint) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
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
