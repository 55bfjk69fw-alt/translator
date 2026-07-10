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
    static let outputLanguageKey = "outputLanguage"
    static let pttOutputLanguageKey = "pttOutputLanguage"
    static let noiseReductionKey = "noiseReduction"

    static func speakerNameKey(_ channel: Int) -> String { "speakerName\(channel)" }

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

    /// Seconds of channel silence before its session is closed (0 = never).
    static var idleCloseSeconds: Double {
        if UserDefaults.standard.object(forKey: idleCloseSecondsKey) == nil { return 120 }
        return UserDefaults.standard.double(forKey: idleCloseSecondsKey)
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
