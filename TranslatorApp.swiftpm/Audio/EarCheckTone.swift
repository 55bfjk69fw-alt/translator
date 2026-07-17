import Foundation

/// The one-on-one mode's Start-time ear check (docs/ONE-ON-ONE.md §2.5):
/// a short cue is scheduled on the lane panned to each bud — left first
/// (low notes), then right (high notes) — through the same player lanes
/// that will carry translations. Each wearer hears exactly one cue in
/// their own ear; hearing both (Mono Audio on, Spatialize Stereo on) or
/// the wrong pitch (buds swapped) flags a misconfiguration before anyone
/// talks. Raw 24 kHz mono PCM16, the exact shape EngineGraph.schedule()
/// consumes — synthesized like AirPodsClaimChime so the .swiftpm needs no
/// bundled asset.
enum EarCheckTone {

    /// Gap between scheduling the left and right cues.
    static let cueSpacing: TimeInterval = 1.1

    /// Low two-note cue for the LEFT bud.
    static let leftPCM16: Data = chime(frequencies: (392, 523))   // G4 → C5

    /// High two-note cue for the RIGHT bud.
    static let rightPCM16: Data = chime(frequencies: (784, 1047)) // G5 → C6

    private static func chime(frequencies: (Double, Double)) -> Data {
        let sampleRate = 24_000.0
        let notes: [(frequency: Double, start: Double, duration: Double)] = [
            (frequencies.0, 0.00, 0.35),
            (frequencies.1, 0.40, 0.45),
        ]
        let frameCount = Int(sampleRate * 0.85)
        var samples = [Int16](repeating: 0, count: frameCount)
        for note in notes {
            let startFrame = Int(note.start * sampleRate)
            let noteFrames = Int(note.duration * sampleRate)
            let attackFrames = max(1, Int(0.012 * sampleRate))
            for i in 0..<noteFrames {
                let frame = startFrame + i
                guard frame < frameCount else { break }
                // Fast attack + cosine decay, the claim chime's soft pluck.
                let attack = min(1, Double(i) / Double(attackFrames))
                let release = 0.5 * (1 + cos(.pi * Double(i) / Double(noteFrames)))
                let value = 0.3 * attack * release * sin(2 * .pi * note.frequency * Double(i) / sampleRate)
                samples[frame] = Int16(max(-32768, min(32767, value * 32767)))
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
