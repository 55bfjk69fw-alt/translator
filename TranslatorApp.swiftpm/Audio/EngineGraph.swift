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

    private(set) var inputChannelCount = 0
    private(set) var inputSampleRate: Double = 48_000
    private(set) var isRunning = false

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

        if let floatData = buffer.floatChannelData {
            // Non-interleaved float32: pass channel pointers straight through.
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(floatData[$0]) }
            onInputChannels?(channels, frames, buffer.format.sampleRate)
        } else {
            Log.warn("Unexpected input buffer layout (no floatChannelData); dropping buffer")
        }
    }

    // MARK: - Playback

    /// Schedule translated audio (24 kHz mono PCM16) on a playback lane.
    func schedule(pcm16: Data, lane: Int, completion: (() -> Void)? = nil) {
        guard players.indices.contains(lane),
              let buffer = Self.pcm16ToFloatBuffer(pcm16, format: playbackFormat) else {
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

    func stopLane(_ lane: Int) {
        guard players.indices.contains(lane) else { return }
        players[lane].stop()
        players[lane].play()
    }

    static func pcm16ToFloatBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let target = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                target[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
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

    /// Silent mono buffer used when the gate suppresses a channel, keeping
    /// the outbound audio timeline continuous.
    static func silentBuffer(frames: Int, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.floatChannelData?[0] {
            data.update(repeating: 0, count: frames)
        }
        return buffer
    }
}
