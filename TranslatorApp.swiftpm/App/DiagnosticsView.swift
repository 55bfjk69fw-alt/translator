import SwiftUI
import AVFoundation
import UIKit

/// Bench-test and event-log screen. This is the first thing to open on new
/// hardware: it shows whether the DJI RX enumerates with 4 channels, whether
/// AirPods stay on A2DP output, and what the translation server is sending.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var log = Log.shared
    @State private var logCopied = false
    @StateObject private var probe = DualInputProbe()
    @StateObject private var cascadeProbe = CascadeProbe()

    // Hosted inside MonitorView's NavigationStack (which owns the pane
    // switcher); this view supplies only its title and toolbar items.
    var body: some View {
        List {
            routeSection
            metersSection
            pipelineSection
            benchSection
            probeSection
            CascadeProbeSection(probe: cascadeProbe)
            logSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { model.refreshRoute() }
            }
        }
        .onAppear { model.refreshRoute() }
        // A conversation/bench start takes over the audio session; kill
        // the probe but leave the session to its new owner.
        .onChange(of: model.mode) { _, newMode in
            if newMode != .idle, probe.running {
                probe.stop(releaseSession: false)
            }
        }
    }

    private var routeSection: some View {
        Section("Audio route") {
            if let route = model.route {
                LabeledContent("Input", value: "\(route.inputName) (\(route.inputType))")
                LabeledContent("Input channels", value: "\(route.inputChannels) (max \(route.maxInputChannels))")
                LabeledContent("Sample rate", value: "\(Int(route.sampleRate)) Hz")
                LabeledContent("Outputs", value: route.outputs.joined(separator: ", "))
                channelVerdict(route: route)
            } else {
                Text("Tap Refresh (or Start) to inspect the audio route.")
                    .foregroundStyle(.secondary)
            }
            Button("Select USB input (DJI RX)") {
                model.audioSession.selectUSBInput()
                model.audioSession.maximizeInputChannels()
                model.refreshRoute()
            }
        }
    }

    @ViewBuilder
    private func channelVerdict(route: AudioSessionController.RouteSnapshot) -> some View {
        if route.inputType == AVAudioSession.Port.usbAudio.rawValue {
            if route.inputChannels >= 4 {
                Label("Quadraphonic capture available — 4 independent speakers supported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if route.inputChannels == 2 {
                Label("Stereo only — set the DJI RX to Q mode; if it stays at 2, iPad gets TX1+TX3 left / TX2+TX4 right", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Mono USB input — check the DJI RX channel mode (M/S/Q)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var metersSection: some View {
        ChannelMetersSection(meters: model.channelMeters, lanes: model.lanes)
    }

    /// Per-lane trace of gate → session → server streams, refreshed at 1 Hz
    /// during a conversation. Built to answer "the gate is open but nothing
    /// shows up in the conversation" (which link is dead?) and "why is the
    /// Chinese text missing" (was source transcription even acknowledged?).
    private var pipelineSection: some View {
        PipelineStatusSection(monitor: model.pipelineMonitor)
    }

    private var benchSection: some View {
        Section("Bench test") {
            if model.mode == .idle {
                Button("Start bench test (no API, meters only)") {
                    model.startBenchTest()
                }
                .disabled(probe.running)
            } else {
                Button("Stop", role: .destructive) {
                    model.stopConversation()
                }
            }
        }
    }

    // MARK: - Dual-input probe

    private var probeSection: some View {
        Section {
            if !probe.running {
                Toggle("Allow Bluetooth mic in session options", isOn: $probe.allowBluetoothOptions)
                Toggle("Request HQ Bluetooth recording (iOS 26)", isOn: $probe.requestHQRecording)
                    .disabled(!DualInputProbe.hqRecordingSupported || !probe.allowBluetoothOptions)
                Button("Start probe (no API cost)") { probe.start() }
                    .disabled(model.mode != .idle)
                if model.mode != .idle {
                    Text("Stop the conversation or bench test first — the probe needs the audio session to itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                probeVerdictRow
                if let route = probe.routeSummary {
                    Text(route)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                probeEngineRows
                probeCaptureRows
                probeSubTestRow
                probeLogRows
                Button("Stop probe", role: .destructive) { probe.stop() }
            }
        } header: {
            Text("Dual-input probe (USB + AirPods mic)")
        } footer: {
            Text("Tests whether a Bluetooth mic can deliver audio while the DJI RX stays the USB input — the capability Apple's Live Translation uses privately. Decisive test: with both streams running, pocket or power off every DJI TX, then speak. Capture meter moves while USB meters stay flat = the AirPods mic is genuinely live alongside USB. Capture at 8–16 kHz that kills the USB meters = the classic single-input collapse. Share the probe log either way — the result goes in docs/RESEARCH.md.")
        }
    }

    @ViewBuilder
    private var probeVerdictRow: some View {
        if probe.captureRunning {
            if probe.engineLive && probe.captureLive {
                Label("Both streams live at once — now do the speak test to confirm which mic feeds capture", systemImage: "checkmark.seal.fill")
                    .font(.callout.bold())
                    .foregroundStyle(.green)
            } else if probe.captureLive {
                Label("Capture live but the USB tap stalled — likely single-input collapse (route stolen)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if probe.engineLive {
                Label("USB live; capture stream silent so far", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("No audio on either stream", systemImage: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var probeEngineRows: some View {
        HStack {
            Label("USB engine", systemImage: probe.engineLive ? "waveform" : "pause.circle")
                .font(.callout)
                .foregroundStyle(probe.engineLive ? .primary : .secondary)
            Spacer()
            if let status = probe.engineStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(Array(probe.engineMeters.enumerated()), id: \.offset) { index, level in
            HStack {
                Text("ch\(index)")
                    .font(.caption.monospaced())
                    .frame(width: 40, alignment: .leading)
                MeterBar(level: level, color: SpeakerLane.laneColors[index % SpeakerLane.laneColors.count])
            }
        }
    }

    @ViewBuilder
    private var probeCaptureRows: some View {
        if probe.devices.count > 1 {
            Picker("Capture device", selection: $probe.selectedDeviceID) {
                ForEach(probe.devices) { device in
                    Text("\(device.name) [\(device.type)]").tag(device.id)
                }
            }
            .disabled(probe.captureRunning)
        } else if let only = probe.devices.first {
            LabeledContent("Capture device", value: "\(only.name) [\(only.type)]")
        }
        if !probe.captureRunning {
            Toggle("Capture on its own private audio session", isOn: $probe.privateCaptureSession)
            HStack {
                Button("Start capture stream") { probe.startCapture() }
                    .buttonStyle(.bordered)
                    .disabled(probe.devices.isEmpty)
                Button("Rescan devices") { probe.refreshDevices() }
                    .buttonStyle(.bordered)
            }
        } else {
            HStack {
                Label("Capture", systemImage: probe.captureLive ? "waveform" : "pause.circle")
                    .font(.callout)
                    .foregroundStyle(probe.captureLive ? .primary : .secondary)
                Spacer()
                if let status = probe.captureStatus {
                    Text(status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("mic")
                    .font(.caption.monospaced())
                    .frame(width: 40, alignment: .leading)
                MeterBar(level: probe.captureMeter, color: .indigo)
            }
            Button("Stop capture stream", role: .destructive) { probe.stopCapture() }
        }
    }

    private var probeSubTestRow: some View {
        HStack {
            Button("Prefer BT input") { probe.preferBluetoothInput() }
            Button("Prefer USB input") { probe.preferUSBInput() }
            Button("Restart USB tap") { probe.startEngineTap() }
        }
        .buttonStyle(.bordered)
        .font(.callout)
    }

    private var probeLogRows: some View {
        DisclosureGroup("Probe log (\(probe.probeLog.count))") {
            ForEach(Array(probe.probeLog.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            ShareLink(item: probe.exportText()) {
                Label("Share probe log", systemImage: "square.and.arrow.up")
                    .font(.callout)
            }
        }
    }

    private var logSection: some View {
        Section {
            ForEach(log.entries.suffix(200).reversed()) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(color(for: entry.level))
                }
            }
        } header: {
            HStack(spacing: 16) {
                Text("Event log")
                Spacer()
                Button(logCopied ? "Copied ✓" : "Copy") {
                    UIPasteboard.general.string = log.exportText()
                    logCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { logCopied = false }
                }
                .font(.caption)
                ShareLink(item: log.exportText()) {
                    Text("Share")
                        .font(.caption)
                }
                Button("Clear") { log.clear() }
                    .font(.caption)
            }
        }
    }

    private func color(for level: Log.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// Observes ChannelMeters directly so the 10 Hz level churn re-renders only
/// these rows, not the whole Diagnostics list.
private struct ChannelMetersSection: View {
    @ObservedObject var meters: ChannelMeters
    let lanes: [SpeakerLane]

    var body: some View {
        Section("Channel meters") {
            if lanes.isEmpty {
                Text("Start the bench test or a conversation to see per-channel levels.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    HStack {
                        Text(lane.name)
                            .frame(width: 100, alignment: .leading)
                            .font(.callout)
                        MeterBar(
                            level: index < meters.levels.count ? meters.levels[index] : 0,
                            color: lane.color
                        )
                    }
                }
                Text("Tap each transmitter in turn — exactly one meter should move per tap if channels are independent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Observes PipelineMonitor directly so the 1 Hz snapshot churn re-renders
/// only these rows, not the whole Diagnostics list (the ChannelMetersSection
/// pattern).
private struct PipelineStatusSection: View {
    @ObservedObject var monitor: PipelineMonitor

    var body: some View {
        Section("Translation pipeline") {
            if monitor.statuses.isEmpty {
                Text("Start a conversation to trace each speaker's audio from the gate through their session to the transcript.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.statuses) { status in
                    LanePipelineRow(status: status)
                }
            }
        }
    }
}

private struct LanePipelineRow: View {
    let status: AppModel.LanePipelineStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(status.name)
                    .font(.callout.bold())
                Text(status.gateOpen ? "gate open" : "gate closed")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(status.gateOpen ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
                    .foregroundStyle(status.gateOpen ? .green : .secondary)
                if let since = status.secondsSinceSpeech {
                    Text("speech \(age(since))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(sessionStateText)
                    .font(.caption.bold())
                    .foregroundStyle(sessionStateColor)
            }
            if let session = realtimeSession {
                Text("Sent \(seconds(session.audioSecondsSent)) audio (\(seconds(session.speechSecondsSent)) speech)\(session.chunksQueuedPreOpen > 0 ? ", \(session.chunksQueuedPreOpen) chunks queued pre-open" : "")\(session.sendFailures > 0 ? ", \(session.sendFailures) SEND FAILURES" : "")")
                    .font(.caption)
                    .foregroundStyle(session.sendFailures > 0 ? .red : .secondary)
                Text("Received: source \(session.sourceChars) ch (\(agePhrase(session.secondsSinceLastSourceDelta))) · translation \(session.translationChars) ch (\(agePhrase(session.secondsSinceLastTranslationDelta))) · audio \(seconds(session.audioSecondsReceived)) (\(agePhrase(session.secondsSinceLastAudioFrame)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Source transcription: \(session.transcriptionAck.summary) · last server event \(age(session.secondsSinceLastServerEvent))")
                    .font(.caption)
                    .foregroundStyle(transcriptionColor(session.transcriptionAck))
                ForEach(symptoms(session), id: \.self) { symptom in
                    Label(symptom, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let cascade = cascadeSession {
                Text("Utterances: \(cascade.utterancesOpened) opened · \(cascade.utterancesFinalized) finalized · \(cascade.utterancesTranslated) translated · \(cascade.utterancesSpoken) spoken\(cascade.audioSkips > 0 ? " · \(cascade.audioSkips) audio skipped" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("STT: \(cascade.volatileChars) volatile / \(cascade.finalChars) final ch · slot \(cascade.holdsSlot ? "held" : "free") · \(cascade.slotWaits) waits\(cascade.bufferedAudioSeconds > 0.5 ? String(format: " · %.1fs buffered", cascade.bufferedAudioSeconds) : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Latency: finalize \(latency(cascade.lastFinalizeSeconds)) · translate \(latency(cascade.lastTranslateSeconds)) · TTS \(latency(cascade.lastTTSFirstAudioSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Stages: STT \(cascade.sttProvider) · MT \(cascade.translationProvider) · TTS apple\(cascade.mtFallbacks > 0 ? " · \(cascade.mtFallbacks) MT fallback\(cascade.mtFallbacks == 1 ? "" : "s")" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = cascade.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(cascadeSymptoms(cascade), id: \.self) { symptom in
                    Label(symptom, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("No session — one opens on this lane's first detected speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func latency(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "—"
    }

    /// Symptom-first lines for the cascade, mirroring the realtime rows'
    /// style: name the broken stage and where to fix it.
    private func cascadeSymptoms(_ snapshot: CascadeSnapshot) -> [String] {
        var lines: [String] = []
        if snapshot.utterancesOpened >= 2, snapshot.volatileChars + snapshot.finalChars == 0 {
            lines.append("Utterances open but NO speech results return — check the speech model in Settings → Translation pipeline")
        }
        if snapshot.utterancesFinalized >= 2, snapshot.utterancesTranslated == 0 {
            lines.append(snapshot.translationProvider == "apple"
                ? "Text finalizes but nothing translates — check the translation pack in Settings → Translation pipeline"
                : "Text finalizes but nothing translates — check network and the API key (Settings → OpenAI)")
        }
        if snapshot.mtFallbackUnavailable {
            lines.append("Cloud translation failing and the offline fallback pack is not installed — download it in Settings → Translation pipeline")
        }
        if let wait = snapshot.lastSlotWaitSeconds, wait > 2 {
            lines.append(String(format: "Last slot wait %.1f s — simultaneous speakers exceeded the speech-model pool", wait))
        }
        return lines
    }

    /// The realtime client counters, when this lane runs the realtime
    /// pipeline.
    private var realtimeSession: RealtimeTranslationClient.Snapshot? {
        switch status.session {
        case .realtime(let session): return session
        case .cascade, nil: return nil
        }
    }

    private var cascadeSession: CascadeSnapshot? {
        switch status.session {
        case .cascade(let snapshot): return snapshot
        case .realtime, nil: return nil
        }
    }

    private var sessionStateText: String {
        if let cascade = cascadeSession {
            switch cascade.state {
            case .idle: return "idle"
            case .starting: return "starting"
            case .running: return "running"
            case .degraded: return "degraded"
            case .reconnecting: return "reconnecting"
            case .failed: return "failed"
            }
        }
        switch realtimeSession?.state {
        case .open:
            if let openFor = realtimeSession?.openForSeconds {
                return "open \(age(openFor, suffix: ""))"
            }
            return "open"
        case .connecting: return "connecting"
        case .closed: return "closed"
        case .idle: return "idle"
        case nil: return "no session"
        }
    }

    private var sessionStateColor: Color {
        if let cascade = cascadeSession {
            switch cascade.state {
            case .running: return .green
            case .starting, .reconnecting: return .yellow
            case .degraded: return .orange
            case .failed: return .red
            case .idle: return .secondary
            }
        }
        switch realtimeSession?.state {
        case .open: return .green
        case .connecting: return .yellow
        case .closed: return .red
        case .idle, nil: return .secondary
        }
    }

    private func transcriptionColor(_ ack: RealtimeTranslationClient.TranscriptionAck) -> Color {
        switch ack {
        case .confirmed: return .secondary
        case .notReceived: return .secondary
        case .absent, .unparseable: return .orange
        }
    }

    /// The same broken-stream signatures the client warns about in the log,
    /// pinned to the row so they're visible without scrolling the event log.
    private func symptoms(_ session: RealtimeTranslationClient.Snapshot) -> [String] {
        var lines: [String] = []
        if case .absent = session.transcriptionAck {
            lines.append("Server ack shows NO source transcription — source text will never arrive on this connection")
        }
        guard session.speechSecondsSent >= 10 else { return lines }
        if session.sourceDeltas + session.translationDeltas + session.audioFrames == 0 {
            lines.append("Speech is reaching the server but nothing is coming back on any stream")
            return lines
        }
        if session.sourceDeltas == 0 {
            lines.append("No source text returned — bubbles will show the translation only")
        }
        if session.audioFrames == 0, session.sourceDeltas > 0 {
            lines.append("No translated audio returned — playback silent for this lane")
        }
        return lines
    }

    private func seconds(_ value: Double) -> String {
        value >= 10 ? "\(Int(value))s" : String(format: "%.1fs", value)
    }

    private func age(_ interval: TimeInterval, suffix: String = " ago") -> String {
        if interval < 60 { return "\(Int(interval))s\(suffix)" }
        return "\(Int(interval / 60))m\(Int(interval.truncatingRemainder(dividingBy: 60)))s\(suffix)"
    }

    private func agePhrase(_ interval: TimeInterval?) -> String {
        interval.map { age($0) } ?? "never"
    }
}

private struct MeterBar: View {
    let level: Float
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, level))))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.1), value: level)
    }
}
