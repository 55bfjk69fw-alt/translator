import Foundation

/// UserDefaults-backed settings shared between the UI (@AppStorage) and the
/// audio/session pipeline (read at start).
enum AppSettings {
    static let endpointTemplateKey = "endpointTemplate"
    static let modelNameKey = "modelName"
    static let autoPlayChineseKey = "autoPlayChinese"
    static let noiseGateEnabledKey = "noiseGateEnabled"
    static let neuralVADEnabledKey = "neuralVADEnabled"
    static let vadThresholdKey = "vadThreshold"
    static let snrFactorKey = "gateSnrFactor"
    static let bleedCorrelationKey = "gateBleedCorrelation"
    static let takeoverMarginKey = "gateTakeoverMargin"
    static let gateHangoverKey = "gateHangover"
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

    /// Single source of truth for the gate-tunable defaults: the accessors
    /// below, the Signal tab's @AppStorage sliders, and ChannelGate must all
    /// agree, and they all read these. Double because @AppStorage stores
    /// Double; the Float accessors convert.
    enum GateDefaults {
        static let vadThreshold = 0.004
        static let snrFactor = 3.0
        static let bleedCorrelation = 0.55
        static let takeoverMargin = 1.25
        static let hangover = 1.5
    }

    /// Minimum RMS for the gate to ever open. The gate's adaptive noise
    /// floor raises the effective threshold above this in noisy rooms.
    static var vadThreshold: Float {
        let value = UserDefaults.standard.float(forKey: vadThresholdKey)
        return value > 0 ? value : Float(GateDefaults.vadThreshold)
    }

    /// Voiced when RMS exceeds the tracked noise floor by this factor.
    static var snrFactor: Float {
        let value = UserDefaults.standard.float(forKey: snrFactorKey)
        return value > 0 ? value : Float(GateDefaults.snrFactor)
    }

    /// Peak cross-correlation at or above which two voiced channels count
    /// as one acoustic source (bleed).
    static var bleedCorrelation: Float {
        let value = UserDefaults.standard.float(forKey: bleedCorrelationKey)
        return value > 0 ? value : Float(GateDefaults.bleedCorrelation)
    }

    /// RMS factor a channel must beat the incumbent by to take over a
    /// correlated pair.
    static var takeoverMargin: Float {
        let value = UserDefaults.standard.float(forKey: takeoverMarginKey)
        return value > 0 ? value : Float(GateDefaults.takeoverMargin)
    }

    /// Seconds the gate stays open after genuine speech (0 is a valid value).
    static var gateHangover: Double {
        if UserDefaults.standard.object(forKey: gateHangoverKey) == nil { return GateDefaults.hangover }
        return UserDefaults.standard.double(forKey: gateHangoverKey)
    }

    /// Remove all persisted gate tunables so the defaults apply again.
    static func resetGateTuning() {
        let defaults = UserDefaults.standard
        for key in [noiseGateEnabledKey, neuralVADEnabledKey, vadThresholdKey,
                    snrFactorKey, bleedCorrelationKey, takeoverMarginKey, gateHangoverKey] {
            defaults.removeObject(forKey: key)
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

    /// Server-side noise reduction type ("near_field"/"far_field"), or nil
    /// when the user turned it off (stored as "off").
    static var noiseReduction: String? {
        let value = UserDefaults.standard.string(forKey: noiseReductionKey) ?? ""
        if value.isEmpty { return "near_field" }
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
