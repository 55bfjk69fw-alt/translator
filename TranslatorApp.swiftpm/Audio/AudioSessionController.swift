import Foundation
import AVFoundation

/// Owns AVAudioSession configuration and routing.
///
/// Core constraint (see docs/RESEARCH.md): iPadOS supports exactly ONE active
/// audio input route. Conversation mode = USB (DJI RX) input + AirPods A2DP
/// output; push-to-talk mode = AirPods mic input (which drops output quality
/// to the HFP link unless iOS 26 high-quality recording engages).
final class AudioSessionController {

    let session = AVAudioSession.sharedInstance()

    struct RouteSnapshot {
        var inputName: String
        var inputType: String
        var inputChannels: Int
        var maxInputChannels: Int
        var outputs: [String]
        var sampleRate: Double
    }

    /// USB in, A2DP out. `.allowBluetoothA2DP` WITHOUT the HFP option is the
    /// key: it keeps AirPods as a high-quality output while a non-Bluetooth
    /// port is the input.
    func configureForConversation() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try session.setActive(true)
        _ = selectUSBInput()
        maximizeInputChannels()
    }

    /// AirPods (or headset) mic in. On iPadOS 26 with H2 AirPods the
    /// high-quality recording link avoids the HFP quality collapse; HFP is
    /// the automatic fallback.
    func configureForPushToTalk() throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        if #available(iOS 26.0, *) {
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        if let bt = bluetoothMicInput() {
            try session.setPreferredInput(bt)
        } else {
            Log.warn("No Bluetooth mic found for push-to-talk; using \(session.currentRoute.inputs.first?.portName ?? "default input")")
        }
    }

    @discardableResult
    func selectUSBInput() -> Bool {
        guard let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) else {
            Log.warn("No USB audio input available (is the DJI RX plugged in?)")
            return false
        }
        do {
            try session.setPreferredInput(usb)
            Log.info("Selected USB input: \(usb.portName)")
            return true
        } catch {
            Log.error("setPreferredInput(USB) failed: \(error.localizedDescription)")
            return false
        }
    }

    private func bluetoothMicInput() -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        return inputs.first(where: { $0.portType == .bluetoothHFP })
            ?? inputs.first(where: { $0.portName.localizedCaseInsensitiveContains("airpods") })
    }

    /// Ask for up to 4 input channels (DJI Quadraphonic). The request is not
    /// a guarantee — read back `inputNumberOfChannels` to see what stuck.
    func maximizeInputChannels() {
        let maxChannels = session.maximumInputNumberOfChannels
        let wanted = min(4, max(1, maxChannels))
        do {
            try session.setPreferredInputNumberOfChannels(wanted)
        } catch {
            Log.warn("setPreferredInputNumberOfChannels(\(wanted)) failed: \(error.localizedDescription)")
        }
        Log.info("Input channels: max=\(maxChannels) requested=\(wanted) actual=\(session.inputNumberOfChannels)")
    }

    func overrideToSpeaker(_ enabled: Bool) {
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            Log.error("Speaker override failed: \(error.localizedDescription)")
        }
    }

    func snapshot() -> RouteSnapshot {
        let route = session.currentRoute
        let input = route.inputs.first
        return RouteSnapshot(
            inputName: input?.portName ?? "none",
            inputType: input?.portType.rawValue ?? "-",
            inputChannels: session.inputNumberOfChannels,
            maxInputChannels: session.maximumInputNumberOfChannels,
            outputs: route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" },
            sampleRate: session.sampleRate
        )
    }

    var usbInputAvailable: Bool {
        session.availableInputs?.contains(where: { $0.portType == .usbAudio }) ?? false
    }

    var airPodsOutputActive: Bool {
        session.currentRoute.outputs.contains { $0.portType == .bluetoothA2DP }
    }
}
