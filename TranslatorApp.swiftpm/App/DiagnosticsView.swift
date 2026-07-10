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

    var body: some View {
        NavigationStack {
            List {
                routeSection
                metersSection
                pipelineSection
                benchSection
                logSection
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { model.refreshRoute() }
                }
            }
            .onAppear { model.refreshRoute() }
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
        Section("Channel meters") {
            if model.lanes.isEmpty {
                Text("Start the bench test or a conversation to see per-channel levels.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.lanes.enumerated()), id: \.element.id) { index, lane in
                    HStack {
                        Text(lane.name)
                            .frame(width: 100, alignment: .leading)
                            .font(.callout)
                        MeterBar(
                            level: index < model.meters.count ? model.meters[index] : 0,
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

    /// Per-lane trace of gate → session → server streams, refreshed at 1 Hz
    /// during a conversation. Built to answer "the gate is open but nothing
    /// shows up in the conversation" (which link is dead?) and "why is the
    /// Chinese text missing" (was source transcription even acknowledged?).
    private var pipelineSection: some View {
        Section("Translation pipeline") {
            if model.pipelineStatuses.isEmpty {
                Text("Start a conversation to trace each speaker's audio from the gate through their session to the transcript.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pipelineStatuses) { status in
                    LanePipelineRow(status: status)
                }
            }
        }
    }

    private var benchSection: some View {
        Section("Bench test") {
            if model.mode == .idle {
                Button("Start bench test (no API, meters only)") {
                    model.startBenchTest()
                }
            } else {
                Button("Stop", role: .destructive) {
                    model.stopConversation()
                }
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
            if let session = status.session {
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
            } else {
                Text("No session — one opens on this lane's first detected speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var sessionStateText: String {
        switch status.session?.state {
        case .open:
            if let openFor = status.session?.openForSeconds {
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
        switch status.session?.state {
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
