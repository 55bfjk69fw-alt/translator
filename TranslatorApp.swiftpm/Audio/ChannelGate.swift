import Foundation

/// Per-channel voice-activity gate plus cross-channel bleed rejection.
///
/// The lav mics all hear the whole room; without gating, one person speaking
/// produces bleed on every channel and duplicate translations. Real
/// beamforming across unsynchronized wireless mics isn't possible, so the
/// gate combines two ideas:
///
///  - **Voicing.** Silero VAD (see SileroVAD.swift) scores each channel's
///    speech probability per 32 ms; unlike an energy threshold it ignores
///    non-speech transients (clothing rustle, dishes) and still detects
///    quiet speakers in loud rooms, where a level-based gate must choose
///    between the two failure modes. An adaptive-RMS detector — noise floor
///    fast-falling, slow-rising, frozen while voiced; voiced when RMS climbs
///    `snrFactor` above it — remains as the fallback when the model can't
///    run (weights missing, non-multiple-of-16 kHz input) or is disabled in
///    Settings. VAD can't replace the bleed logic below: bleed IS speech,
///    so a speech detector fires on every channel that hears it.
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
    /// tracked noise floor falls. User-adjustable in Settings. Applies in
    /// both voicing modes: with the VAD it suppresses far-field speech that
    /// is genuinely someone else's (too faint to be the wearer).
    var minimumVoiceThreshold: Float = 0.004
    /// Voiced when RMS exceeds the tracked noise floor by this factor (~10 dB).
    /// Fallback mode only.
    var snrFactor: Float = 3.0
    /// Silero probability that opens voicing, and the lower level it must
    /// drop below to close it — hysteresis so probabilities hovering around
    /// the threshold don't chatter mid-utterance. Same split as the official
    /// silero-vad iterator (threshold / threshold − 0.15). User-adjustable
    /// per mic profile: the ambient profile opens lower because Silero
    /// scores far-field speech less confidently.
    var vadOnProbability: Float = 0.5
    var vadOffProbability: Float = 0.35
    /// Settings toggle: use the neural VAD when its weights are available.
    var neuralVADEnabled = true
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
    /// Profile-dependent: the ambient profile doubles it, since surrounding
    /// multi-person chatter legitimately stays voiced far longer than one
    /// worn mic's wearer ever does.
    var sustainedVoiceTimeout: TimeInterval = 6
    var enabled = true

    /// Correlation runs on decimated copies near this rate: speech keeps
    /// plenty of energy below 2 kHz, and it makes the lag search cheap
    /// enough for the audio queue (≲1M multiplies per 200 ms worst case).
    private let correlationRate: Double = 4000

    // MARK: - State

    /// Loaded once for the process; each channel gets its own model state.
    private static let vadWeights: SileroVAD.Weights? = {
        guard let url = vadWeightsURL(),
              let data = try? Data(contentsOf: url),
              let weights = SileroVAD.Weights(data: data) else { return nil }
        return weights
    }()

    /// Swift Playgrounds' build of app playgrounds does not synthesize the
    /// SwiftPM `Bundle.module` accessor, so look in the app bundle first and
    /// then in any nested SwiftPM resource bundles.
    private static func vadWeightsURL() -> URL? {
        let name = "silero_vad_16k"
        let ext = "svad"
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        for bundleURL in Bundle.main.urls(forResourcesWithExtension: "bundle", subdirectory: nil) ?? [] {
            if let nested = Bundle(url: bundleURL),
               let url = nested.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private var vads: [StreamingVAD] = []
    /// Per-channel hysteresis: currently above the on threshold.
    private var vadHold: [Bool] = []
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
        /// made (before this buffer's noise-floor update). In neural-VAD
        /// mode the threshold is just `minimumVoiceThreshold` (the floor
        /// keeps tracking but does not drive voicing); in RMS-fallback mode
        /// it is max(minimumVoiceThreshold, floor * snrFactor).
        var noiseFloor: Float
        var effectiveThreshold: Float
        /// Silero speech probability for this buffer; nil when the neural
        /// VAD is off, unavailable, or produced no score for this buffer.
        var vadProbability: Float?
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

        // 1. Voicing: Silero probability with hysteresis when the model is
        // available, adaptive-RMS otherwise. The noise floor keeps updating
        // in both modes (fast-falling, creeping up only while unvoiced, so
        // it never climbs into ongoing speech) — it stays warm in case a
        // buffer arrives at a rate the VAD can't consume.
        let useVAD = neuralVADEnabled && !vads.isEmpty
        var voicedNow = [Bool](repeating: false, count: count)
        var thresholds = [Float](repeating: 0, count: count)
        // Floors captured pre-update so telemetry shows the floor/threshold
        // pair the decision was actually made against.
        var floors = [Float](repeating: 0, count: count)
        var probabilities = [Float?](repeating: nil, count: count)
        for i in 0..<count {
            floors[i] = noiseFloor[i]
            if isEnabled(i), useVAD, rms[i] < minimumVoiceThreshold {
                // Sub-threshold buffers can never be voiced (VAD voicing
                // also requires rms >= minimumVoiceThreshold), so skip the
                // neural inference entirely — otherwise every silent
                // channel (a powered-off TX is pure zeros) pays the full
                // forward pass continuously. Clearing the hold mirrors the
                // disabled-channel path below; the model recovers from the
                // state gap within a frame or two of speech returning.
                vadHold[i] = false
                thresholds[i] = minimumVoiceThreshold
                voicedNow[i] = false
            } else if isEnabled(i), useVAD,
               let probability = vads[i].feed(channels[i], count: frames, sampleRate: sampleRate) {
                probabilities[i] = probability
                thresholds[i] = minimumVoiceThreshold
                vadHold[i] = probability >= (vadHold[i] ? vadOffProbability : vadOnProbability)
                voicedNow[i] = vadHold[i] && rms[i] >= minimumVoiceThreshold
            } else {
                // Disabled channels skip the VAD entirely (no wasted
                // inference; the model recovers from the state gap within a
                // frame or two of re-enabling).
                if !isEnabled(i) { vadHold[i] = false }
                let threshold = max(minimumVoiceThreshold, noiseFloor[i] * snrFactor)
                thresholds[i] = threshold
                voicedNow[i] = isEnabled(i) && rms[i] >= threshold
            }

            // Steady noise above the initial threshold would freeze the
            // floor and keep the channel voiced forever; only an unbroken
            // voiced run longer than any human breath group distinguishes
            // it from speech, and past that the floor unfreezes below.
            // (Protects the RMS fallback; with the VAD deciding voicing,
            // steady noise never reads as voiced in the first place.)
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
                vadProbability: probabilities[i],
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
        vads.removeAll()
        vadHold.removeAll()
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
        vadHold = Array(repeating: false, count: channelCount)
        if let weights = Self.vadWeights {
            vads = (0..<channelCount).map { _ in StreamingVAD(weights: weights) }
            Log.info("Gate: Silero VAD voicing active (\(channelCount) channels)")
        } else {
            vads = []
            Log.warn("Gate: VAD weights unavailable; using adaptive-RMS voicing")
        }
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
