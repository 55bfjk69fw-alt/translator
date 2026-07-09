import Foundation

/// Per-channel voice-activity gate plus cross-channel dominance logic.
///
/// The 4 lav mics all hear the whole room; without gating, one person
/// speaking produces bleed on every channel and four duplicate translations.
/// Real beamforming across unsynchronized wireless mics isn't possible, so:
///  - a channel is "voiced" when its RMS exceeds the threshold (with a
///    hangover so word gaps don't chatter), and
///  - a voiced channel is suppressed when another channel is much louder
///    (the dominant speaker's own mic wins; bleed sits well below it).
/// Suppressed audio is replaced with silence rather than dropped so each
/// session's audio timeline stays continuous, as the API expects.
final class ChannelGate {

    var voiceThreshold: Float = 0.010
    /// A channel must be within this factor of the loudest channel's RMS to
    /// pass (0.3 ~= within ~10 dB — lav-to-lav bleed is typically far lower).
    var dominanceRatio: Float = 0.3
    // Generous hangover: gating quiet sentence-endings to silence feeds the
    // model chopped audio and directly degrades translation quality. The
    // cost is a longer bleed-exposure window after each utterance.
    var hangover: TimeInterval = 1.5
    var enabled = true

    private var lastVoiced: [Int: Date] = [:]

    struct Decision {
        var rms: Float
        var voiced: Bool
        var pass: Bool
    }

    /// Evaluate all channels for one buffer interval.
    func evaluate(rmsPerChannel: [Float]) -> [Decision] {
        let now = Date()
        let loudest = rmsPerChannel.max() ?? 0

        return rmsPerChannel.enumerated().map { index, rms in
            let voicedNow = rms >= voiceThreshold
            if voicedNow { lastVoiced[index] = now }
            let inHangover = (lastVoiced[index].map { now.timeIntervalSince($0) <= hangover }) ?? false
            let voiced = voicedNow || inHangover

            guard enabled else {
                return Decision(rms: rms, voiced: voiced, pass: true)
            }
            let dominantEnough = loudest <= 0 || rms >= loudest * dominanceRatio || voicedNow && rms >= voiceThreshold * 3
            return Decision(rms: rms, voiced: voiced, pass: voiced && dominantEnough)
        }
    }

    func reset() {
        lastVoiced.removeAll()
    }

    static func rms(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sum += s * s
        }
        return (sum / Float(count)).squareRoot()
    }
}
