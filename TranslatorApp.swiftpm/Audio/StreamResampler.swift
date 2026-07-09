import Foundation
import AVFoundation

/// Streaming converter: mono Float32 at the hardware rate -> mono Int16 at
/// 24 kHz (the realtime API's `audio/pcm` format). One instance per channel;
/// AVAudioConverter keeps filter state across calls for gapless resampling.
final class StreamResampler {

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    private let converter: AVAudioConverter
    let inputFormat: AVAudioFormat

    init?(inputSampleRate: Double) {
        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: Self.targetFormat) else {
            return nil
        }
        self.inputFormat = inFormat
        self.converter = converter
    }

    /// Convert one mono buffer; returns little-endian PCM16 bytes at 24 kHz.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
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
            if let error { Log.warn("Resample failed: \(error.localizedDescription)") }
            return nil
        }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
