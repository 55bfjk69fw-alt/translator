import Foundation
import AVFoundation

/// Owns AVAudioSession configuration and routing.
///
/// Core constraint (see docs/RESEARCH.md): iPadOS publicly supports exactly
/// ONE active input route. The app only ever uses USB (DJI RX) input +
/// AirPods A2DP output — the user's replies are spoken aloud from cue cards
/// (docs/REPLY-FLOW.md), never captured. The AirPods mic is touched only by
/// the Diagnostics dual-input probe.
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
