import Foundation

/// Per-channel voice-activity gate plus cross-channel bleed rejection.
///
/// The lav mics all hear the whole room; without gating, one person speaking
/// produces bleed on every channel and duplicate translations. Real
/// beamforming across unsynchronized wireless mics isn't possible, so the
/// gate combines two ideas:
///
///  - **Adaptive voicing.** Each channel tracks its own noise floor
///    (fast-falling, slow-rising, frozen while voiced) and is "voiced" when
///    its RMS climbs `snrFactor` above that floor. Thresholds self-tune to
///    the room instead of relying on one hand-set constant; the old constant
///    survives only as an absolute minimum.
///  - **Bleed rejection by cross-correlation.** Bleed is the *same* waveform
///    on two mics — delayed by acoustics/radio and attenuated — so when two
///    channels are voiced in the same buffer, a high peak cross-correlation
///    across a small lag window marks them as one source, and only the
///    loudest copy passes. Two people genuinely talking at once correlate
///    weakly (each mic is dominated by its own wearer's voice), so both
///    pass: simultaneous speakers survive, duplicates don't. A loudness
///    ratio alone can't make that distinction — it mutes quiet speakers
///    whenever someone else talks louder.
///
/// Decisions use only the current buffer (no look-ahead), so the gate adds
/// zero latency. Suppressed audio is replaced with silence rather than
/// dropped so each session's audio timeline stays continuous, as the API
/// expects.
final class ChannelGate {

    // MARK: - Tunables

    /// Absolute RMS below which a channel is never voiced, however low its
    /// tracked noise floor falls. User-adjustable in Settings.
    var minimumVoiceThreshold: Float = 0.004
    /// Voiced when RMS exceeds the tracked noise floor by this factor (~10 dB).
    var snrFactor: Float = 3.0
    /// Peak normalized cross-correlation at or above which two voiced
    /// channels count as one acoustic source. In simulation, bleed-only
    /// channels score ≥0.9 even with heavy coloration and noise, while
    /// genuine double-talk stays below ~0.5 because each mic is dominated
    /// by its own wearer — 0.55 splits the two with margin on both sides.
    var bleedCorrelation: Float = 0.55
    /// Half-width of the lag search: acoustic propagation (~3 ms/m) plus the
    /// spread in per-transmitter radio latency.
    var maxLagSeconds: Float = 0.025
    /// To take a correlated pair over from the incumbent loudest mic, a
    /// channel must beat it by this RMS factor — hysteresis so near-equal
    /// mics don't flip-flop mid-word.
    var takeoverMargin: Float = 1.25
    // Generous hangover: gating quiet sentence-endings to silence feeds the
    // model chopped audio and directly degrades translation quality. The
    // cost is a longer bleed-exposure window after each utterance.
    var hangover: TimeInterval = 1.5
    /// A channel voiced continuously for this long — not one sub-threshold
    /// 200 ms buffer — is carrying steady noise (mic hiss with onboard NC
    /// off, ventilation), not speech: speakers always pause to breathe.
    /// Past the timeout the floor unfreezes so it can climb over the noise.
    var sustainedVoiceTimeout: TimeInterval = 6
    var enabled = true

    /// Correlation runs on decimated copies near this rate: speech keeps
    /// plenty of energy below 2 kHz, and it makes the lag search cheap
    /// enough for the audio queue (≲1M multiplies per 200 ms worst case).
    private let correlationRate: Double = 4000

    // MARK: - State

    private var noiseFloor: [Float] = []
    private var lastGenuine: [Int: Date] = [:]
    /// When each channel's current unbroken run of voiced buffers began.
    private var voicedSince: [Int: Date] = [:]
    private var wasSustainedNoise: Set<Int> = []
    /// pairKey(i,j) -> channel currently winning that correlated pair.
    /// Rebuilt every buffer so entries vanish as soon as a pair stops being
    /// co-voiced or stops correlating (i.e. real double-talk resumes).
    private var pairWinner: [Int: Int] = [:]
    private var wasBleed: Set<Int> = []
    private var scratch: [[Float]] = []

    struct Decision {
        var rms: Float
        var voiced: Bool
        /// Send this channel's audio (false = replace with silence).
        var pass: Bool
        /// Voiced, but suppressed as bleed of a louder correlated channel.
        var bleed: Bool
    }

    // MARK: - Telemetry
    //
    // Everything the gate knew when it made its last decisions, for the
    // Signal tab. audioQueue-confined like the rest of the gate's state:
    // read it synchronously right after evaluate() and pass a value copy on.

    struct ChannelTelemetry {
        var rms: Float
        /// Floor and threshold as they stood when the voicing decision was
        /// made (before this buffer's noise-floor update), so the pair is
        /// always consistent: threshold == max(min, floor * snr).
        var noiseFloor: Float
        var effectiveThreshold: Float
        var voiced: Bool
        var pass: Bool
        var bleed: Bool
    }

    struct PairTelemetry {
        var a: Int
        var b: Int
        var correlation: Float
        /// Set only when the pair correlated at or above `bleedCorrelation`.
        var winner: Int?
    }

    struct Telemetry {
        var channels: [ChannelTelemetry] = []
        /// One entry per correlation actually computed this buffer, i.e.
        /// pairs that were both voiced. Everything else was never measured.
        var pairs: [PairTelemetry] = []
    }

    private(set) var lastTelemetry = Telemetry()

    /// Evaluate all channels for one buffer interval. The pointers must stay
    /// valid for the duration of the call. `channelEnabled` hard-mutes
    /// channels the user turned off in Settings: they are never voiced,
    /// never pass, and never participate in bleed pairing (a muted channel
    /// must not steal a correlated pair from a live one).
    func evaluate(channels: [UnsafePointer<Float>], frames: Int, sampleRate: Double, channelEnabled: [Bool]? = nil) -> [Decision] {
        let now = Date()
        let count = channels.count
        ensureState(channelCount: count)
        func isEnabled(_ i: Int) -> Bool {
            guard let channelEnabled, i < channelEnabled.count else { return true }
            return channelEnabled[i]
        }

        let rms = channels.map { Self.rms(samples: $0, count: frames) }

        // 1. Adaptive voicing. The floor falls quickly toward quiet frames
        // and creeps up only during frames that aren't voiced, so it never
        // climbs into ongoing speech.
        var voicedNow = [Bool](repeating: false, count: count)
        var thresholds = [Float](repeating: 0, count: count)
        // Floors captured pre-update so telemetry shows the floor/threshold
        // pair the decision was actually made against.
        var floors = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let threshold = max(minimumVoiceThreshold, noiseFloor[i] * snrFactor)
            thresholds[i] = threshold
            floors[i] = noiseFloor[i]
            voicedNow[i] = isEnabled(i) && rms[i] >= threshold

            // Steady noise above the initial threshold would freeze the
            // floor and keep the channel voiced forever; only an unbroken
            // voiced run longer than any human breath group distinguishes
            // it from speech, and past that the floor unfreezes below.
            var sustainedNoise = false
            if voicedNow[i] {
                let since = voicedSince[i] ?? now
                voicedSince[i] = since
                sustainedNoise = now.timeIntervalSince(since) > sustainedVoiceTimeout
            } else {
                voicedSince[i] = nil
            }
            if sustainedNoise && !wasSustainedNoise.contains(i) {
                wasSustainedNoise.insert(i)
                Log.info("Gate: ch\(i) voiced \(Int(sustainedVoiceTimeout))s without a pause — treating as steady noise, raising its floor")
            } else if !voicedNow[i] {
                wasSustainedNoise.remove(i)
            }

            if rms[i] < noiseFloor[i] {
                noiseFloor[i] += (rms[i] - noiseFloor[i]) * 0.5
            } else if !voicedNow[i] || sustainedNoise {
                noiseFloor[i] = min(rms[i], noiseFloor[i] * 1.05 + 1e-6)
            }
        }

        // 2. Bleed rejection among concurrently voiced channels.
        var bleed = [Bool](repeating: false, count: count)
        var pairTelemetry: [PairTelemetry] = []
        let active = (0..<count).filter { voicedNow[$0] }
        var winners: [Int: Int] = [:]
        if enabled && active.count >= 2 {
            let factor = max(1, Int(sampleRate / correlationRate))
            let maxLag = max(1, Int(Float(sampleRate) * maxLagSeconds) / factor)
            for i in active {
                Self.decimate(channels[i], frames: frames, factor: factor, into: &scratch[i])
            }
            for (offset, i) in active.enumerated() {
                for j in active.dropFirst(offset + 1) {
                    let corr = Self.peakCorrelation(scratch[i], scratch[j], maxLag: maxLag)
                    guard corr >= bleedCorrelation else {
                        pairTelemetry.append(PairTelemetry(a: i, b: j, correlation: corr, winner: nil))
                        continue
                    }
                    let key = pairKey(i, j)
                    let winner: Int
                    if let incumbent = pairWinner[key] {
                        let challenger = incumbent == i ? j : i
                        winner = rms[challenger] > rms[incumbent] * takeoverMargin ? challenger : incumbent
                    } else {
                        winner = rms[i] >= rms[j] ? i : j
                    }
                    winners[key] = winner
                    bleed[winner == i ? j : i] = true
                    pairTelemetry.append(PairTelemetry(a: i, b: j, correlation: corr, winner: winner))
                }
            }
        }
        pairWinner = winners

        // 3. Decisions. Suppression overrides hangover: once a channel is
        // identified as bleed, its hangover must not pass the other
        // speaker's words into this channel's session.
        var decisions: [Decision] = []
        decisions.reserveCapacity(count)
        var channelTelemetry: [ChannelTelemetry] = []
        channelTelemetry.reserveCapacity(count)
        for i in 0..<count {
            let genuine = voicedNow[i] && !bleed[i]
            if genuine { lastGenuine[i] = now }
            let inHangover = lastGenuine[i].map { now.timeIntervalSince($0) <= hangover } ?? false
            let voiced = voicedNow[i] || inHangover
            // A user-disabled channel never passes, even with the gate off.
            let pass = isEnabled(i) && (!enabled || (!bleed[i] && (genuine || inHangover)))
            decisions.append(Decision(rms: rms[i], voiced: voiced, pass: pass, bleed: bleed[i]))
            channelTelemetry.append(ChannelTelemetry(
                rms: rms[i],
                noiseFloor: floors[i],
                effectiveThreshold: thresholds[i],
                voiced: voiced,
                pass: pass,
                bleed: bleed[i]
            ))

            if bleed[i] && !wasBleed.contains(i) {
                Log.info("Gate: ch\(i) suppressed as bleed of a louder channel")
                wasBleed.insert(i)
            } else if !bleed[i] {
                wasBleed.remove(i)
            }
        }
        lastTelemetry = Telemetry(channels: channelTelemetry, pairs: pairTelemetry)
        return decisions
    }

    func reset() {
        noiseFloor.removeAll()
        lastGenuine.removeAll()
        voicedSince.removeAll()
        wasSustainedNoise.removeAll()
        pairWinner.removeAll()
        wasBleed.removeAll()
        scratch.removeAll()
        lastTelemetry = Telemetry()
    }

    // MARK: - Internals

    private func ensureState(channelCount: Int) {
        guard noiseFloor.count != channelCount else { return }
        noiseFloor = Array(repeating: minimumVoiceThreshold, count: channelCount)
        scratch = Array(repeating: [], count: channelCount)
        lastGenuine.removeAll()
        voicedSince.removeAll()
        wasSustainedNoise.removeAll()
        pairWinner.removeAll()
        wasBleed.removeAll()
    }

    private func pairKey(_ i: Int, _ j: Int) -> Int {
        (min(i, j) << 8) | max(i, j)
    }

    /// Block-mean decimation with DC removal. Crude as a low-pass, but both
    /// channels of a bleed pair alias identically so correlation survives.
    static func decimate(_ samples: UnsafePointer<Float>, frames: Int, factor: Int, into out: inout [Float]) {
        let outCount = frames / factor
        out.removeAll(keepingCapacity: true)
        guard outCount > 0 else { return }
        out.reserveCapacity(outCount)
        var index = 0
        var total: Float = 0
        for _ in 0..<outCount {
            var sum: Float = 0
            for k in 0..<factor { sum += samples[index + k] }
            index += factor
            let value = sum / Float(factor)
            total += value
            out.append(value)
        }
        let mean = total / Float(outCount)
        for k in 0..<outCount { out[k] -= mean }
    }

    /// Peak of the normalized cross-correlation of two zero-mean signals
    /// over lags in ±maxLag. Amplitude-invariant, so a heavily attenuated
    /// bleed copy still scores high.
    static func peakCorrelation(_ a: [Float], _ b: [Float], maxLag: Int) -> Float {
        let n = min(a.count, b.count)
        guard n > 0, maxLag < n else { return 0 }
        return a.withUnsafeBufferPointer { pa -> Float in
            b.withUnsafeBufferPointer { pb -> Float in
                var energyA: Float = 0
                var energyB: Float = 0
                for k in 0..<n {
                    energyA += pa[k] * pa[k]
                    energyB += pb[k] * pb[k]
                }
                let norm = (energyA * energyB).squareRoot()
                guard norm > 1e-12 else { return 0 }
                var best: Float = 0
                for lag in -maxLag...maxLag {
                    var sum: Float = 0
                    if lag >= 0 {
                        for k in 0..<(n - lag) { sum += pa[k + lag] * pb[k] }
                    } else {
                        for k in 0..<(n + lag) { sum += pa[k] * pb[k - lag] }
                    }
                    if sum > best { best = sum }
                }
                return best / norm
            }
        }
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
