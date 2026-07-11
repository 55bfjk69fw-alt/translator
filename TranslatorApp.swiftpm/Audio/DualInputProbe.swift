import Foundation
import AVFoundation
import CoreMedia
import Combine

/// Diagnostics workbench for one question: can this device deliver the
/// AirPods microphone WHILE the DJI RX stays the active USB input?
///
/// Apple's Live Translation demonstrably captures the AirPods mics alongside
/// the active input route, but through a private path; the public
/// AVAudioSession model allows a single input route (docs/RESEARCH.md). This
/// probe tries the two candidate *public* paths on real hardware:
///
///  1. Session options: `.playAndRecord` + `.allowBluetoothHFP` +
///     `.bluetoothHighQualityRecording` (iOS 26) with USB as the preferred
///     input — does a Bluetooth mic even appear alongside USB, and does
///     selecting it add to or replace the USB route?
///  2. A second capture stack: our AVAudioEngine tap holds the USB input
///     while a separate AVCaptureSession (optionally on its own private
///     audio session) captures a microphone device — do BOTH deliver live
///     buffers at once?
///
/// Everything observable is logged so a run can be shared and pasted into
/// docs/RESEARCH.md. The decisive physical test: with both streams running,
/// pocket/power off every DJI TX and speak — if the capture meter moves while
/// the USB meters stay flat, the AirPods mic is genuinely live next to USB
/// (and not just re-hearing the USB route).
///
/// Main-thread only, except the tap/delegate callbacks which stash levels
/// under `stateLock` for the UI timer to publish.
final class DualInputProbe: NSObject, ObservableObject {

    struct DeviceOption: Identifiable, Equatable {
        let id: String     // AVCaptureDevice.uniqueID
        let name: String
        let type: String
    }

    // MARK: - Published UI state (main thread)

    @Published private(set) var running = false
    @Published private(set) var captureRunning = false

    /// Include `.allowBluetoothHFP` (+ HQ below) in the session options.
    /// Off = the app's normal conversation config, as a control case.
    @Published var allowBluetoothOptions = true
    /// Add `.bluetoothHighQualityRecording` (iOS 26, H2 AirPods) so the HQ
    /// link is preferred over HFP wherever the system honors it.
    @Published var requestHQRecording = true
    /// Run the capture stack on its own private audio session instead of
    /// the app's shared one — the configuration most likely to yield a
    /// second, independent input.
    @Published var privateCaptureSession = true

    @Published private(set) var devices: [DeviceOption] = []
    @Published var selectedDeviceID: String = ""

    @Published private(set) var engineMeters: [Float] = []
    @Published private(set) var engineStatus: String?
    @Published private(set) var engineLive = false
    @Published private(set) var captureMeter: Float = 0
    @Published private(set) var captureStatus: String?
    @Published private(set) var captureLive = false
    @Published private(set) var routeSummary: String?
    @Published private(set) var probeLog: [String] = []

    static var hqRecordingSupported: Bool {
        if #available(iOS 26.0, *) { return true } else { return false }
    }

    // MARK: - Internals

    private let engine = AVAudioEngine()
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "translator.probe.capture", qos: .userInitiated)

    /// Guards everything below (written from the tap thread and the capture
    /// queue, read by the main-thread UI timer).
    private let stateLock = NSLock()
    private var engineRMS: [Float] = []
    private var engineBuffers = 0
    private var lastEngineBufferAt: Date?
    private var captureRMS: Float = 0
    private var captureBuffers = 0
    private var lastCaptureBufferAt: Date?
    private var captureFormatLine: String?

    private var engineFormatLine = ""
    private var uiTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Lifecycle

    /// Configure the shared session for the experiment, start the USB engine
    /// tap, and enumerate capture devices. Caller ensures the app is idle
    /// (no conversation/bench engine fighting over the session).
    func start() {
        guard !running else { return }
        running = true
        probeLog.removeAll()
        log("Probe started — can the AirPods mic run alongside USB (DJI) input?")

        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        var optionNames = ["allowBluetoothA2DP"]
        if allowBluetoothOptions {
            options.insert(.allowBluetoothHFP)
            optionNames.append("allowBluetoothHFP")
            if #available(iOS 26.0, *), requestHQRecording {
                options.insert(.bluetoothHighQualityRecording)
                optionNames.append("bluetoothHighQualityRecording")
            } else if requestHQRecording {
                log("HQ Bluetooth recording requested but requires iOS 26 — continuing with HFP only")
            }
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setActive(true)
            log("Session active: playAndRecord [\(optionNames.joined(separator: ", "))]")
        } catch {
            log("Session setup FAILED: \(error.localizedDescription)")
        }

        preferUSBInput()
        let wanted = min(4, max(1, session.maximumInputNumberOfChannels))
        try? session.setPreferredInputNumberOfChannels(wanted)
        logAvailableInputs()
        observeNotifications()
        refreshDevices()
        startUITimer()
        // The preferred-input switch settles asynchronously (same 0.3 s
        // dance as elsewhere in the app) — install the tap after it lands so
        // the engine binds the USB format, not a transient route's.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.running else { return }
            self.startEngineTap()
            self.logRoute(context: "after session setup")
        }
    }

    /// `releaseSession: false` when something else (a starting conversation)
    /// has already taken over the shared session — deactivating it out from
    /// under the new owner would kill their audio.
    func stop(releaseSession: Bool = true) {
        guard running else { return }
        stopCapture()
        stopEngineTap()
        uiTimer?.invalidate()
        uiTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        log(releaseSession ? "Probe stopped — releasing the audio session" : "Probe stopped — session left to its new owner")
        if releaseSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        running = false
        engineLive = false
        captureLive = false
        engineStatus = nil
        captureStatus = nil
        engineMeters = []
        captureMeter = 0
        routeSummary = nil
    }

    // MARK: - USB engine side

    /// (Re)install the input tap against the CURRENT route format. Also the
    /// recovery button after a route flip auto-stops the engine.
    func startEngineTap() {
        stopEngineTap()
        let format = engine.inputNode.inputFormat(forBus: 0)
        let channels = Int(format.channelCount)
        guard channels > 0 else {
            log("Engine input has 0 channels — no capture device on the app session's route")
            return
        }
        stateLock.lock()
        engineRMS = Array(repeating: 0, count: channels)
        engineBuffers = 0
        lastEngineBufferAt = nil
        stateLock.unlock()
        engineFormatLine = "\(channels)ch @ \(Int(format.sampleRate)) Hz"
        engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            self?.handleEngineBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            log("USB-side engine tap running: \(engineFormatLine)")
        } catch {
            log("Engine start FAILED: \(error.localizedDescription)")
        }
    }

    private func stopEngineTap() {
        // Remove unconditionally (safe no-op when absent; double-install is
        // fatal), mirroring EngineGraph.stop().
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()
    }

    private func handleEngineBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData,
              !buffer.format.isInterleaved || buffer.format.channelCount == 1 else { return }
        let channels = Int(buffer.format.channelCount)
        var rms: [Float] = []
        rms.reserveCapacity(channels)
        for channel in 0..<channels {
            rms.append(ChannelGate.rms(samples: UnsafePointer(data[channel]), count: frames))
        }
        stateLock.lock()
        engineRMS = rms
        engineBuffers += 1
        lastEngineBufferAt = Date()
        stateLock.unlock()
    }

    // MARK: - Capture-stack side

    func refreshDevices() {
        var found: [DeviceOption] = []
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        for device in discovery.devices {
            found.append(DeviceOption(id: device.uniqueID, name: device.localizedName, type: shortType(device.deviceType.rawValue)))
        }
        if found.isEmpty, let fallback = AVCaptureDevice.default(for: .audio) {
            found.append(DeviceOption(id: fallback.uniqueID, name: fallback.localizedName, type: shortType(fallback.deviceType.rawValue)))
        }
        devices = found
        if selectedDeviceID.isEmpty || !found.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = found.first?.id ?? ""
        }
        log("Capture devices: \(found.isEmpty ? "NONE found" : found.map { "\($0.name) [\($0.type)]" }.joined(separator: "; "))")
        if found.count == 1 {
            log("A single pseudo-device usually follows the session's route — the speak test below tells you which physical mic actually feeds it")
        }
    }

    func startCapture() {
        guard running, !captureRunning else { return }
        guard let device = AVCaptureDevice(uniqueID: selectedDeviceID) else {
            log("Selected capture device no longer available — rescan")
            return
        }
        let capture = AVCaptureSession()
        capture.usesApplicationAudioSession = !privateCaptureSession
        if #available(iOS 26.0, *) {
            capture.configuresApplicationAudioSessionForBluetoothHighQualityRecording = requestHQRecording
        }
        capture.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard capture.canAddInput(input) else {
                log("Capture session rejected input \(device.localizedName)")
                capture.commitConfiguration()
                return
            }
            capture.addInput(input)
        } catch {
            log("Capture input FAILED: \(error.localizedDescription)")
            capture.commitConfiguration()
            return
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard capture.canAddOutput(output) else {
            log("Capture session rejected the audio data output")
            capture.commitConfiguration()
            return
        }
        capture.addOutput(output)
        capture.commitConfiguration()

        stateLock.lock()
        captureRMS = 0
        captureBuffers = 0
        lastCaptureBufferAt = nil
        captureFormatLine = nil
        stateLock.unlock()

        captureSession = capture
        captureRunning = true
        log("Starting capture stream: \(device.localizedName), \(privateCaptureSession ? "PRIVATE audio session" : "shared app session")\(Self.hqRecordingSupported ? ", HQ recording \(requestHQRecording ? "on" : "off")" : "")")
        // startRunning() blocks until the stack is up — keep it off main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            capture.startRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.log(capture.isRunning ? "Capture session reports running" : "Capture session did NOT start")
                // The other half of the verdict: did spinning up the capture
                // stack steal or reshape the app session's route?
                self.logRoute(context: "after capture start")
            }
        }
    }

    func stopCapture() {
        guard let capture = captureSession else { return }
        captureSession = nil
        captureRunning = false
        captureLive = false
        captureStatus = nil
        captureMeter = 0
        DispatchQueue.global(qos: .userInitiated).async { capture.stopRunning() }
        log("Capture stream stopped")
        logRoute(context: "after capture stop")
    }

    // MARK: - Route sub-tests

    /// Explicit single-route experiment: point the shared session's
    /// preferred input at the Bluetooth mic and watch what the route does —
    /// replacement (classic collapse) or addition (the interesting result).
    func preferBluetoothInput() {
        let session = AVAudioSession.sharedInstance()
        logRoute(context: "before Bluetooth-input switch")
        let inputs = session.availableInputs ?? []
        guard let bt = inputs.first(where: { $0.portType == .bluetoothHFP })
                ?? inputs.first(where: { $0.portName.localizedCaseInsensitiveContains("airpods") }) else {
            log("No Bluetooth mic in availableInputs — nothing to switch to (HQ/HFP mic not offered on this route)")
            return
        }
        do {
            try session.setPreferredInput(bt)
            log("Preferred input → \(bt.portName) [\(bt.portType.rawValue)]")
        } catch {
            log("setPreferredInput(\(bt.portName)) FAILED: \(error.localizedDescription)")
        }
        // The route settles asynchronously; log where it landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.logRoute(context: "after Bluetooth-input switch")
        }
    }

    @discardableResult
    func preferUSBInput() -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) else {
            log("No USB input available — plug in the DJI RX (probe continues without it)")
            return false
        }
        do {
            try session.setPreferredInput(usb)
            log("Preferred input → USB: \(usb.portName)")
            return true
        } catch {
            log("setPreferredInput(USB) FAILED: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Evidence log

    func exportText() -> String {
        probeLog.joined(separator: "\n")
    }

    private func log(_ message: String) {
        Log.info("[probe] \(message)")
        let line = "\(Self.timeFormatter.string(from: Date())) \(message)"
        if Thread.isMainThread {
            probeLog.append(line)
        } else {
            DispatchQueue.main.async { self.probeLog.append(line) }
        }
    }

    private func logAvailableInputs() {
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        log("Available inputs (\(inputs.count)): \(inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: "; "))")
        if !inputs.contains(where: { $0.portType == .bluetoothHFP || $0.portName.localizedCaseInsensitiveContains("airpods") }) {
            log("NOTE: no Bluetooth mic offered — if AirPods are connected, this itself is a finding (HQ/HFP input not exposed next to USB)")
        }
    }

    private func logRoute(context: String) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let ins = route.inputs.map { "\($0.portName) [\($0.portType.rawValue)] ch=\($0.channels?.count ?? 0)" }.joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        log("Route (\(context)): in \(ins.isEmpty ? "none" : ins) → out \(outs.isEmpty ? "none" : outs)")
    }

    private func shortType(_ raw: String) -> String {
        raw.replacingOccurrences(of: "AVCaptureDeviceType", with: "")
    }

    // MARK: - Observers & UI timer

    private func observeNotifications() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.running else { return }
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            self.logRoute(context: "route change, reason \(reason.map { String(describing: $0) } ?? "unknown")")
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            self.log("USB-side engine auto-stopped (I/O configuration changed) — tap halted; use 'Restart USB tap' to resume against the new route")
        })
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.publishSnapshot()
        }
    }

    private func publishSnapshot() {
        stateLock.lock()
        let rms = engineRMS
        let engineCount = engineBuffers
        let engineAt = lastEngineBufferAt
        let cRMS = captureRMS
        let captureCount = captureBuffers
        let captureAt = lastCaptureBufferAt
        let format = captureFormatLine
        captureRMS *= 0.7   // peak-hold decay between capture callbacks
        stateLock.unlock()

        let now = Date()
        engineMeters = rms.map { min(1, $0 * 12) }
        engineLive = engineAt.map { now.timeIntervalSince($0) < 1.5 } ?? false
        engineStatus = engineCount > 0
            ? "\(engineFormatLine) — \(engineCount) buffers"
            : "\(engineFormatLine) — no buffers yet"
        captureMeter = min(1, cRMS * 12)
        captureLive = captureAt.map { now.timeIntervalSince($0) < 1.5 } ?? false
        if captureRunning {
            captureStatus = captureCount > 0
                ? "\(captureCount) buffers — \(format ?? "format unknown")"
                : "no buffers yet"
        }
        let route = AVAudioSession.sharedInstance().currentRoute
        let input = route.inputs.first
        routeSummary = "in: \(input?.portName ?? "none") [\(input?.portType.rawValue ?? "-")] → out: \(route.outputs.map(\.portName).joined(separator: ", "))"
    }
}

// MARK: - Capture delegate

extension DualInputProbe: AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var asbd: AudioStreamBasicDescription?
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0, length < 1_000_000 else { return }
        // Copy instead of taking a data pointer: always succeeds, even for
        // non-contiguous block buffers, and the callbacks are only a few KB.
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else { return }
        let rms = Self.rms(bytes: bytes, asbd: asbd)

        var formatLine = "unknown format"
        if let asbd {
            let kind = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "float" : "int"
            formatLine = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame)ch, \(asbd.mBitsPerChannel)-bit \(kind)"
        }

        stateLock.lock()
        captureRMS = max(rms, captureRMS)
        captureBuffers += 1
        lastCaptureBufferAt = Date()
        let firstBuffer = captureFormatLine == nil
        if firstBuffer { captureFormatLine = formatLine }
        stateLock.unlock()

        if firstBuffer {
            // The format itself is evidence: HFP delivers 8/16 kHz; the
            // iOS 26 HQ AirPods link delivers 48 kHz.
            log("First capture buffer: \(formatLine)")
        }
    }

    private static func rms(bytes: [UInt8], asbd: AudioStreamBasicDescription?) -> Float {
        let isFloat = ((asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat) != 0
        let bits = Int(asbd?.mBitsPerChannel ?? 16)
        var sum = 0.0
        var count = 0
        bytes.withUnsafeBytes { raw in
            if isFloat, bits == 32 {
                let samples = raw.bindMemory(to: Float32.self)
                for sample in samples { sum += Double(sample * sample) }
                count = samples.count
            } else if bits == 16 {
                let samples = raw.bindMemory(to: Int16.self)
                for sample in samples {
                    let value = Double(sample) / 32768.0
                    sum += value * value
                }
                count = samples.count
            } else if bits == 32 {
                let samples = raw.bindMemory(to: Int32.self)
                for sample in samples {
                    let value = Double(sample) / 2147483648.0
                    sum += value * value
                }
                count = samples.count
            }
        }
        guard count > 0 else { return 0 }
        return Float((sum / Double(count)).squareRoot())
    }
}
