import Foundation

/// UserDefaults-backed settings shared between the UI (@AppStorage) and the
/// audio/session pipeline (read at start).
enum AppSettings {
    static let endpointTemplateKey = "endpointTemplate"
    static let modelNameKey = "modelName"
    static let autoPlayChineseKey = "autoPlayChinese"
    static let noiseGateEnabledKey = "noiseGateEnabled"
    static let vadThresholdKey = "vadThreshold"
    static let snrFactorKey = "gateSnrFactor"
    static let bleedCorrelationKey = "gateBleedCorrelation"
    static let takeoverMarginKey = "gateTakeoverMargin"
    static let gateHangoverKey = "gateHangover"
    static let userNameKey = "userName"
    static let idleCloseSecondsKey = "idleCloseSeconds"
    static let showPinyinKey = "showPinyin"

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

    /// Voiced when RMS exceeds the tracked noise floor by this factor.
    static var snrFactor: Float {
        let value = UserDefaults.standard.float(forKey: snrFactorKey)
        return value > 0 ? value : 3.0
    }

    /// Peak cross-correlation at or above which two voiced channels count
    /// as one acoustic source (bleed).
    static var bleedCorrelation: Float {
        let value = UserDefaults.standard.float(forKey: bleedCorrelationKey)
        return value > 0 ? value : 0.55
    }

    /// RMS factor a channel must beat the incumbent by to take over a
    /// correlated pair.
    static var takeoverMargin: Float {
        let value = UserDefaults.standard.float(forKey: takeoverMarginKey)
        return value > 0 ? value : 1.25
    }

    /// Seconds the gate stays open after genuine speech (0 is a valid value).
    static var gateHangover: Double {
        if UserDefaults.standard.object(forKey: gateHangoverKey) == nil { return 1.5 }
        return UserDefaults.standard.double(forKey: gateHangoverKey)
    }

    /// Remove all persisted gate tunables so the defaults apply again.
    static func resetGateTuning() {
        let defaults = UserDefaults.standard
        for key in [noiseGateEnabledKey, vadThresholdKey, snrFactorKey,
                    bleedCorrelationKey, takeoverMarginKey, gateHangoverKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Seconds of channel silence before its session is closed (0 = never).
    static var idleCloseSeconds: Double {
        if UserDefaults.standard.object(forKey: idleCloseSecondsKey) == nil { return 120 }
        return UserDefaults.standard.double(forKey: idleCloseSecondsKey)
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
