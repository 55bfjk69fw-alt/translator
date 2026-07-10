import Foundation

/// UserDefaults-backed settings shared between the UI (@AppStorage) and the
/// audio/session pipeline (read at start).
enum AppSettings {
    static let endpointTemplateKey = "endpointTemplate"
    static let modelNameKey = "modelName"
    static let autoPlayChineseKey = "autoPlayChinese"
    static let noiseGateEnabledKey = "noiseGateEnabled"
    static let neuralVADEnabledKey = "neuralVADEnabled"
    static let micProfileKey = "micProfile"
    static let vadThresholdKey = "vadThreshold"
    static let snrFactorKey = "gateSnrFactor"
    static let bleedCorrelationKey = "gateBleedCorrelation"
    static let takeoverMarginKey = "gateTakeoverMargin"
    static let gateHangoverKey = "gateHangover"
    static let vadOnProbabilityKey = "gateVadOnProbability"
    static let userNameKey = "userName"
    static let idleCloseSecondsKey = "idleCloseSeconds"
    static let showPinyinKey = "showPinyin"
    static let outputGainKey = "outputGain"
    static let outputLanguageKey = "outputLanguage"
    static let pttOutputLanguageKey = "pttOutputLanguage"
    static let noiseReductionKey = "noiseReduction"

    static func speakerNameKey(_ channel: Int) -> String { "speakerName\(channel)" }
    static func speakerEnabledKey(_ channel: Int) -> String { "speakerEnabled\(channel)" }

    static var endpointTemplate: String {
        let value = UserDefaults.standard.string(forKey: endpointTemplateKey) ?? ""
        return value.isEmpty ? SessionConfig.defaultEndpointTemplate : value
    }

    static var modelName: String {
        let value = UserDefaults.standard.string(forKey: modelNameKey) ?? ""
        return value.isEmpty ? "gpt-realtime-translate" : value
    }

    static var autoPlayChinese: Bool {
        UserDefaults.standard.bool(forKey: autoPlayChineseKey)
    }

    static var noiseGateEnabled: Bool {
        UserDefaults.standard.object(forKey: noiseGateEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: noiseGateEnabledKey)
    }

    /// Voicing via the on-device Silero VAD model instead of the adaptive
    /// RMS threshold (the gate falls back to RMS when this is off).
    static var neuralVADEnabled: Bool {
        UserDefaults.standard.object(forKey: neuralVADEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: neuralVADEnabledKey)
    }

    // MARK: - Mic placement profiles

    /// How the mics are being used, which picks the gate tuning that makes
    /// sense physically. `worn` is the original setup — a lav clipped to
    /// each speaker's chest, where far-field speech is *someone else's* and
    /// must be suppressed. `ambient` inverts that: one carried/worn mic (or
    /// a chest mic plus a second in hand) listening to conversations around
    /// the wearer, where far-field speech is exactly the signal.
    ///
    /// Each profile has its own defaults *and* its own persisted tuning —
    /// the worn profile keeps the original UserDefaults keys, so switching
    /// to ambient and back restores the worn setup untouched.
    enum MicProfile: String, CaseIterable, Identifiable {
        case worn
        case ambient
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .worn: return "Worn on speakers"
            case .ambient: return "Ambient (carried)"
            }
        }
    }

    static var micProfile: MicProfile {
        MicProfile(rawValue: UserDefaults.standard.string(forKey: micProfileKey) ?? "") ?? .worn
    }

    /// Storage key for a tunable under a profile. The worn profile owns the
    /// bare (pre-profile) keys so existing tuning survives the upgrade.
    static func profileKey(_ base: String, _ profile: MicProfile) -> String {
        profile == .worn ? base : "\(base).\(profile.rawValue)"
    }

    /// Single source of truth for the gate-tunable defaults: the accessors
    /// below, the tuning sliders' @AppStorage, and ChannelGate must all
    /// agree, and they all read these. Double because @AppStorage stores
    /// Double; the Float accessors convert.
    struct GateDefaults {
        var vadThreshold: Double
        var snrFactor: Double
        var bleedCorrelation: Double
        var takeoverMargin: Double
        var hangover: Double
        var vadOnProbability: Double
        var sustainedVoiceTimeout: Double
        var noiseReduction: String
    }

    static func gateDefaults(for profile: MicProfile) -> GateDefaults {
        switch profile {
        case .worn:
            // The original chest-lav tuning, unchanged: the wearer's mouth
            // is ~20 cm from the capsule, so anything faint is bleed.
            return GateDefaults(
                vadThreshold: 0.004,
                snrFactor: 3.0,
                bleedCorrelation: 0.55,
                takeoverMargin: 1.25,
                hangover: 1.5,
                vadOnProbability: 0.5,
                sustainedVoiceTimeout: 6,
                noiseReduction: "near_field"
            )
        case .ambient:
            // Target speech is 1-4 m away — roughly 15-25 dB quieter than
            // mouth-distance speech — so the absolute floor drops, the VAD
            // opens on lower confidence (Silero scores far speech lower),
            // the hangover stretches (low-SNR speech reads as choppier),
            // and OpenAI's far-field noise reduction replaces near-field.
            // The steady-noise timeout doubles: surrounding chatter can run
            // well past 6 s without the channel ever going unvoiced.
            return GateDefaults(
                vadThreshold: 0.001,
                snrFactor: 2.0,
                bleedCorrelation: 0.55,
                takeoverMargin: 1.25,
                hangover: 2.0,
                vadOnProbability: 0.35,
                sustainedVoiceTimeout: 12,
                noiseReduction: "far_field"
            )
        }
    }

    /// Minimum RMS for the gate to ever open. The gate's adaptive noise
    /// floor raises the effective threshold above this in noisy rooms.
    static func vadThreshold(for profile: MicProfile) -> Float {
        let value = UserDefaults.standard.float(forKey: profileKey(vadThresholdKey, profile))
        return value > 0 ? value : Float(gateDefaults(for: profile).vadThreshold)
    }
    static var vadThreshold: Float { vadThreshold(for: micProfile) }

    /// Voiced when RMS exceeds the tracked noise floor by this factor.
    static func snrFactor(for profile: MicProfile) -> Float {
        let value = UserDefaults.standard.float(forKey: profileKey(snrFactorKey, profile))
        return value > 0 ? value : Float(gateDefaults(for: profile).snrFactor)
    }
    static var snrFactor: Float { snrFactor(for: micProfile) }

    /// Peak cross-correlation at or above which two voiced channels count
    /// as one acoustic source (bleed).
    static func bleedCorrelation(for profile: MicProfile) -> Float {
        let value = UserDefaults.standard.float(forKey: profileKey(bleedCorrelationKey, profile))
        return value > 0 ? value : Float(gateDefaults(for: profile).bleedCorrelation)
    }
    static var bleedCorrelation: Float { bleedCorrelation(for: micProfile) }

    /// RMS factor a channel must beat the incumbent by to take over a
    /// correlated pair.
    static func takeoverMargin(for profile: MicProfile) -> Float {
        let value = UserDefaults.standard.float(forKey: profileKey(takeoverMarginKey, profile))
        return value > 0 ? value : Float(gateDefaults(for: profile).takeoverMargin)
    }
    static var takeoverMargin: Float { takeoverMargin(for: micProfile) }

    /// Seconds the gate stays open after genuine speech (0 is a valid value).
    static func gateHangover(for profile: MicProfile) -> Double {
        let key = profileKey(gateHangoverKey, profile)
        if UserDefaults.standard.object(forKey: key) == nil { return gateDefaults(for: profile).hangover }
        return UserDefaults.standard.double(forKey: key)
    }
    static var gateHangover: Double { gateHangover(for: micProfile) }

    /// Silero probability that opens voicing; the close threshold is
    /// derived 0.15 below it, the same split the official iterator uses.
    static func vadOnProbability(for profile: MicProfile) -> Float {
        let value = UserDefaults.standard.float(forKey: profileKey(vadOnProbabilityKey, profile))
        return value > 0 ? value : Float(gateDefaults(for: profile).vadOnProbability)
    }
    static var vadOnProbability: Float { vadOnProbability(for: micProfile) }
    static var vadOffProbability: Float { max(0.05, vadOnProbability - 0.15) }

    /// Unbroken voicing longer than this is reclassified as steady noise.
    /// Per-profile constant (no slider): ambient surroundings legitimately
    /// stay voiced far longer than a single worn mic ever should.
    static var sustainedVoiceTimeout: Double {
        gateDefaults(for: micProfile).sustainedVoiceTimeout
    }

    /// Remove the active profile's persisted gate tunables (and the global
    /// gate/VAD toggles) so its defaults apply again. The other profile's
    /// tuning is untouched.
    static func resetGateTuning(profile: MicProfile) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: noiseGateEnabledKey)
        defaults.removeObject(forKey: neuralVADEnabledKey)
        for base in [vadThresholdKey, snrFactorKey, bleedCorrelationKey,
                     takeoverMarginKey, gateHangoverKey, vadOnProbabilityKey] {
            defaults.removeObject(forKey: profileKey(base, profile))
        }
    }

    /// Master playback volume (1.0 = 100%). Below 1 attenuates on the
    /// mixer; above 1 digitally boosts translated audio before playback.
    static var outputGain: Float {
        let value = UserDefaults.standard.float(forKey: outputGainKey)
        return value > 0 ? value : 1.0
    }

    /// Seconds of channel silence before its session is closed (0 = never).
    static var idleCloseSeconds: Double {
        if UserDefaults.standard.object(forKey: idleCloseSecondsKey) == nil { return 120 }
        return UserDefaults.standard.double(forKey: idleCloseSecondsKey)
    }

    /// Whether a DJI channel participates at all (default on). Disabled
    /// channels are hard-muted: never voiced, never open a session. Read
    /// per buffer so toggling in Settings applies mid-conversation.
    static func speakerEnabled(_ channel: Int) -> Bool {
        UserDefaults.standard.object(forKey: speakerEnabledKey(channel)) == nil
            ? true
            : UserDefaults.standard.bool(forKey: speakerEnabledKey(channel))
    }

    /// Target language for the DJI speaker lanes (what the table's speech is
    /// translated into). ISO-639-1, one of the model's 13 output languages.
    static var outputLanguage: String {
        let value = UserDefaults.standard.string(forKey: outputLanguageKey) ?? ""
        return value.isEmpty ? "en" : value
    }

    /// Target language for the push-to-talk return channel (what the user's
    /// speech is translated into).
    static var pttOutputLanguage: String {
        let value = UserDefaults.standard.string(forKey: pttOutputLanguageKey) ?? ""
        return value.isEmpty ? "zh" : value
    }

    /// Server-side noise reduction type ("near_field"/"far_field"/"off") as
    /// stored for a profile, defaulting per profile (worn = near_field,
    /// ambient = far_field).
    static func noiseReductionSetting(for profile: MicProfile) -> String {
        let value = UserDefaults.standard.string(forKey: profileKey(noiseReductionKey, profile)) ?? ""
        return value.isEmpty ? gateDefaults(for: profile).noiseReduction : value
    }

    /// The active profile's noise reduction for the session payload, or nil
    /// when the user turned it off (stored as "off").
    static var noiseReduction: String? {
        let value = noiseReductionSetting(for: micProfile)
        return value == "off" ? nil : value
    }

    static func speakerName(_ channel: Int) -> String {
        let value = UserDefaults.standard.string(forKey: speakerNameKey(channel)) ?? ""
        return value.isEmpty ? "Speaker \(channel + 1)" : value
    }

    static var userName: String {
        let value = UserDefaults.standard.string(forKey: userNameKey) ?? ""
        return value.isEmpty ? "Me" : value
    }
}
