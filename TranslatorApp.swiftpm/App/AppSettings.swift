import Foundation

/// UserDefaults-backed settings shared between the UI (@AppStorage) and the
/// audio/session pipeline (read at start).
enum AppSettings {
    static let endpointTemplateKey = "endpointTemplate"
    static let modelNameKey = "modelName"
    static let autoPlayChineseKey = "autoPlayChinese"
    static let noiseGateEnabledKey = "noiseGateEnabled"
    static let vadThresholdKey = "vadThreshold"
    static let userNameKey = "userName"
    static let idleCloseSecondsKey = "idleCloseSeconds"
    static let showPinyinKey = "showPinyin"
    static let outputGainKey = "outputGain"

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

    /// Minimum RMS for the gate to ever open. The gate's adaptive noise
    /// floor raises the effective threshold above this in noisy rooms.
    static var vadThreshold: Float {
        let value = UserDefaults.standard.float(forKey: vadThresholdKey)
        return value > 0 ? value : 0.004
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

    static func speakerName(_ channel: Int) -> String {
        let value = UserDefaults.standard.string(forKey: speakerNameKey(channel)) ?? ""
        return value.isEmpty ? "Speaker \(channel + 1)" : value
    }

    static var userName: String {
        let value = UserDefaults.standard.string(forKey: userNameKey) ?? ""
        return value.isEmpty ? "Me" : value
    }
}
