import Foundation
import AVFoundation

/// AVAudioEngine wrapper: one multichannel input tap (DJI RX or AirPods mic,
/// whichever is the session's single input) and one player node per
/// translation stream for playback.
final class EngineGraph {

    let engine = AVAudioEngine()

    /// Mono float channels extracted from the input tap, hardware rate.
    /// Called on the audio tap thread — do minimal work and hop queues.
    var onInputChannels: (([UnsafePointer<Float>], Int, Double) -> Void)?

    private var players: [AVAudioPlayerNode] = []
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    /// Master playback volume (1.0 = unity). Attenuation below 1 goes on
    /// the main mixer and applies instantly, including to already-scheduled
    /// audio; boost above 1 is baked into each subsequent buffer (the mixer
    /// can't exceed unity) with samples clamped at full scale. Main-thread
    /// only, like schedule(). Survives engine rebuilds.
    var outputGain: Float = 1.0 {
        didSet { applyMixerGain() }
    }

    private var boostFactor: Float { max(1, outputGain) }

    private func applyMixerGain() {
        engine.mainMixerNode.outputVolume = min(1, max(0, outputGain))
    }

    private(set) var inputChannelCount = 0
    private(set) var inputSampleRate: Double = 48_000
    private(set) var isRunning = false

    private var configChangeObserver: NSObjectProtocol?

    init() {
        // AVAudioEngine silently stops itself when its I/O configuration
        // changes underneath it (Bluetooth codec renegotiation, USB device
        // hiccup) — often during quiet periods. Nothing else reports this,
        // so log it loudly and clear isRunning; AppModel's watchdog restarts
        // the graph.
        // queue: .main so isRunning is only ever touched on the main thread
        // (the notification posts on an internal CoreAudio thread otherwise).
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            Log.warn("Audio engine configuration changed — engine auto-stopped (capture and playback halted until restart)")
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// (Re)build the graph for the current route. `playerCount` playback
    /// lanes are attached regardless of input shape so translated audio can
    /// keep playing in every mode.
    func start(playerCount: Int) throws {
        stop()

        for _ in 0..<max(1, playerCount) {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            players.append(player)
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        inputChannelCount = Int(format.channelCount)
        inputSampleRate = format.sampleRate
        Log.info("Engine input: \(inputChannelCount)ch @ \(Int(format.sampleRate)) Hz, \(format.commonFormat == .pcmFormatFloat32 ? "float32" : "other"), interleaved=\(format.isInterleaved)")

        guard inputChannelCount > 0 else {
            throw NSError(domain: "EngineGraph", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Input has 0 channels — no capture device on the current route."
            ])
        }

        // 9600 frames @48k = 200 ms per callback, matching the translation
        // engine's 200 ms frame size (OpenAI recommends appending in 200 ms
        // chunks; shorter chunks are buffered server-side anyway).
        input.installTap(onBus: 0, bufferSize: 9600, format: format) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer)
        }

        applyMixerGain()
        engine.prepare()
        try engine.start()
        players.forEach { $0.play() }
        isRunning = true
    }

    func stop() {
        // Remove unconditionally: a tap can be left installed when start()
        // threw after installing it, and removing a nonexistent tap is a
        // safe no-op — while installing a second tap is a fatal exception.
        engine.inputNode.removeTap(onBus: 0)
        if isRunning || engine.isRunning {
            engine.stop()
        }
        for player in players {
            engine.detach(player)
        }
        players.removeAll()
        engine.reset()
        isRunning = false
    }

    private func handleInput(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Interleaved multichannel float32 would still return non-nil
        // floatChannelData, but only index 0 is a valid pointer — fanning
        // out per-channel pointers from it reads garbage. iOS input taps
        // are deinterleaved in practice; drop loudly if that ever changes.
        if let floatData = buffer.floatChannelData,
           !buffer.format.isInterleaved || buffer.format.channelCount == 1 {
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(floatData[$0]) }
            onInputChannels?(channels, frames, buffer.format.sampleRate)
        } else {
            Log.warn("Unexpected input buffer layout (interleaved or no floatChannelData); dropping buffer")
        }
    }

    // MARK: - Playback

    /// Schedule translated audio (24 kHz mono PCM16) on a playback lane.
    func schedule(pcm16: Data, lane: Int, completion: (() -> Void)? = nil) {
        guard players.indices.contains(lane),
              let buffer = Self.pcm16ToFloatBuffer(pcm16, format: playbackFormat, gain: boostFactor) else {
            completion?()
            return
        }
        let player = players[lane]
        if let completion {
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completion()
            }
        } else {
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
        if isRunning && !player.isPlaying {
            player.play()
        }
    }

    /// Duck (or restore) a playback lane's volume.
    func setLaneVolume(_ volume: Float, lane: Int) {
        guard players.indices.contains(lane) else { return }
        players[lane].volume = volume
    }

    static func pcm16ToFloatBuffer(_ data: Data, format: AVAudioFormat, gain: Float = 1) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let target = buffer.floatChannelData?[0] else { return nil }
        let scale = gain / 32768.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                target[i] = max(-1, min(1, Float(Int16(littleEndian: samples[i])) * scale))
            }
        }
        return buffer
    }

    /// Mono hardware-rate copy of one channel, for feeding a StreamResampler.
    static func monoBuffer(from samples: UnsafePointer<Float>, frames: Int, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData?[0].update(from: samples, count: frames)
        return buffer
    }
}
