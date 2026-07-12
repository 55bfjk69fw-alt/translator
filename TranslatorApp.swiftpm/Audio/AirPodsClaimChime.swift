import Foundation
import AVFoundation

/// The audible half of the Start-time AirPods claim (see
/// AudioSessionController.configureForPlaybackClaim). iPadOS's automatic
/// switching moves AirPods to the device that *starts playing media* —
/// merely activating a session, or a session playing silence, doesn't
/// count. This plays a short two-note chime through the claim session,
/// which is both the switching trigger and an in-ear confirmation: hear it
/// in the AirPods and the claim worked; hear it from the iPad speaker and
/// they're still attached to the phone.
final class AirPodsClaimChime {

    private var player: AVAudioPlayer?

    /// Total chime length. The claim keeps its playback session up at least
    /// this long so the chime isn't cut short by the category flip.
    static let duration: TimeInterval = 1.0

    func play() {
        do {
            let player = try AVAudioPlayer(data: Self.wavData)
            player.volume = 0.6
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // The claim still ran (the session is active); losing the chime
            // only weakens the switching signal and the in-ear confirmation.
            Log.warn("Claim chime failed to play: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - Synthesis

    /// Two soft rising notes (~1 s), 24 kHz mono PCM16 in a WAV container —
    /// synthesized so the .swiftpm needs no bundled sound asset.
    private static let wavData: Data = {
        let sampleRate = 24_000.0
        let notes: [(frequency: Double, start: Double, duration: Double)] = [
            (660, 0.00, 0.40),
            (880, 0.45, 0.55),
        ]
        let frameCount = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: frameCount)
        for note in notes {
            let startFrame = Int(note.start * sampleRate)
            let noteFrames = Int(note.duration * sampleRate)
            let attackFrames = max(1, Int(0.012 * sampleRate))
            for i in 0..<noteFrames {
                let frame = startFrame + i
                guard frame < frameCount else { break }
                // Fast attack + cosine decay over the whole note: a soft
                // pluck with no clicks at either edge.
                let attack = min(1, Double(i) / Double(attackFrames))
                let release = 0.5 * (1 + cos(.pi * Double(i) / Double(noteFrames)))
                let value = 0.28 * attack * release * sin(2 * .pi * note.frequency * Double(i) / sampleRate)
                samples[frame] = Int16(max(-32768, min(32767, value * 32767)))
            }
        }
        return wav(samples: samples, sampleRate: Int(sampleRate))
    }()

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + byteCount)
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                        // fmt chunk size
        append16(1)                         // PCM
        append16(1)                         // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))    // byte rate
        append16(2)                         // block align
        append16(16)                        // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
