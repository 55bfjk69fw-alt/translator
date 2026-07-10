import Foundation
import AVFoundation

/// Plays voice samples for the Settings voice pickers. Two paths:
///  - On-device: resolve through OnDeviceSynthesizer.resolveVoice (the same
///    code path a lane uses, so the preview is honest) and speak() — free.
///  - OpenAI: a real (small) /v1/audio/speech call; the returned 24 kHz
///    PCM16 is wrapped in a WAV header and played with AVAudioPlayer,
///    because the AVAudioEngine isn't running while browsing Settings so
///    EngineGraph playback is unavailable. Preview cost is deliberately
///    unmetered: CostMeter is per-conversation and previews are outside it.
///
/// Both players are retained properties — releasing an AVSpeechSynthesizer
/// or AVAudioPlayer mid-playback stops it.
@MainActor
final class VoicePreviewController: NSObject, ObservableObject {

    /// Storage key of the row currently playing (drives the stop icon).
    @Published private(set) var activeRowID: String?
    @Published private(set) var lastError: String?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?
    // Current playback objects, compared by identity so a late
    // didFinish/didCancel from a superseded preview can't clear the newly
    // active row. (Object identity, not ObjectIdentifier of a dead object —
    // a freed address can be reused by the next allocation.)
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Short sample per output language (English fallback).
    static func samplePhrase(for languageCode: String) -> String {
        let primary = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        let phrases: [String: String] = [
            "en": "Hi, this is how I sound.",
            "zh": "你好，这是我的声音。",
            "es": "Hola, así sueno.",
            "fr": "Bonjour, voici ma voix.",
            "de": "Hallo, so klinge ich.",
            "it": "Ciao, questa è la mia voce.",
            "pt": "Olá, esta é a minha voz.",
            "ja": "こんにちは、私の声です。",
            "ko": "안녕하세요, 제 목소리입니다.",
            "ar": "مرحباً، هذا صوتي."
        ]
        return phrases[primary] ?? phrases["en"]!
    }

    func previewOnDevice(rowID: String, explicitVoiceID: String?, laneIndex: Int,
                         languageCode: String, excludedVoices: Set<String>, appIsIdle: Bool) {
        stop()
        guard let voice = OnDeviceSynthesizer.resolveVoice(
            explicitIdentifier: explicitVoiceID, laneIndex: laneIndex,
            languageCode: languageCode, excluding: excludedVoices
        ) else {
            lastError = "No installed voice for “\(languageCode)”."
            return
        }
        activateSessionIfNeeded(appIsIdle: appIsIdle)
        let utterance = AVSpeechUtterance(string: Self.samplePhrase(for: languageCode))
        utterance.voice = voice
        currentUtterance = utterance
        activeRowID = rowID
        lastError = nil
        speechSynthesizer.speak(utterance)
    }

    func previewOpenAI(rowID: String, explicitVoice: String?, laneIndex: Int,
                       languageCode: String, model: String,
                       excludedVoices: Set<String>, appIsIdle: Bool) {
        stop()
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            lastError = "Add your OpenAI API key first."
            return
        }
        activeRowID = rowID
        lastError = nil
        let synthesizer = OpenAISynthesizer(
            apiKey: apiKey, model: model, explicitVoice: explicitVoice,
            laneIndex: laneIndex, excludedVoices: excludedVoices)
        fetchTask = Task { [weak self] in
            do {
                var pcm = Data()
                for try await chunk in synthesizer.synthesize(
                    text: VoicePreviewController.samplePhrase(for: languageCode), languageCode: languageCode
                ) {
                    // .usage ignored on purpose — previews are unmetered.
                    if case .audio(let data) = chunk { pcm.append(data) }
                }
                guard let self, !Task.isCancelled else { return }
                guard !pcm.isEmpty else {
                    self.lastError = "Preview returned no audio."
                    self.activeRowID = nil
                    return
                }
                self.activateSessionIfNeeded(appIsIdle: appIsIdle)
                let player = try AVAudioPlayer(data: wavData(pcm16: pcm))
                player.delegate = self
                self.audioPlayer = player
                player.play()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.lastError = "Preview failed: \(error.localizedDescription)"
                self.activeRowID = nil
            }
        }
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        currentUtterance = nil
        activeRowID = nil
    }

    /// While a conversation is live the session is playAndRecord on the
    /// conversation route — previews just mix over it, untouched. While
    /// idle the last-set category may not be playable, so switch to plain
    /// playback. Never deactivated afterwards: the next Start reconfigures.
    private func activateSessionIfNeeded(appIsIdle: Bool) {
        guard appIsIdle else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func clearIfCurrent(utterance: AVSpeechUtterance? = nil, player: AVAudioPlayer? = nil) {
        if let utterance, utterance !== currentUtterance { return }
        if let player, player !== audioPlayer { return }
        audioPlayer = nil
        currentUtterance = nil
        activeRowID = nil
    }
}

extension VoicePreviewController: AVSpeechSynthesizerDelegate {
    // Delegate callbacks may arrive off-main; hop and compare against the
    // retained current objects (weak captures — a superseded object either
    // stays distinguishable or is already nil).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, weak utterance] in
            guard let utterance else { return }
            self?.clearIfCurrent(utterance: utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, weak utterance] in
            guard let utterance else { return }
            self?.clearIfCurrent(utterance: utterance)
        }
    }
}

extension VoicePreviewController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let player else { return }
            self?.clearIfCurrent(player: player)
        }
    }
}

/// Minimal canonical RIFF/WAVE wrapper (44-byte header) around raw PCM16 LE
/// so AVAudioPlayer can play synthesizer output without the audio engine.
func wavData(pcm16: Data, sampleRate: Int = 24_000, channels: Int = 1) -> Data {
    var wav = Data(capacity: 44 + pcm16.count)
    wav.append(contentsOf: Array("RIFF".utf8))
    wav.appendLittleEndian(UInt32(36 + pcm16.count))
    wav.append(contentsOf: Array("WAVE".utf8))
    wav.append(contentsOf: Array("fmt ".utf8))
    wav.appendLittleEndian(UInt32(16))                                  // fmt chunk size
    wav.appendLittleEndian(UInt16(1))                                   // PCM
    wav.appendLittleEndian(UInt16(channels))
    wav.appendLittleEndian(UInt32(sampleRate))
    wav.appendLittleEndian(UInt32(sampleRate * channels * 2))           // byte rate
    wav.appendLittleEndian(UInt16(channels * 2))                        // block align
    wav.appendLittleEndian(UInt16(16))                                  // bits per sample
    wav.append(contentsOf: Array("data".utf8))
    wav.appendLittleEndian(UInt32(pcm16.count))
    wav.append(pcm16)
    return wav
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLittleEndian(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
