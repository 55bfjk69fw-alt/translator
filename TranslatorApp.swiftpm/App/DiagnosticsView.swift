import SwiftUI
import AVFoundation

/// Bench-test and event-log screen. This is the first thing to open on new
/// hardware: it shows whether the DJI RX enumerates with 4 channels, whether
/// AirPods stay on A2DP output, and what the translation server is sending.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var log = Log.shared

    var body: some View {
        NavigationStack {
            List {
                routeSection
                metersSection
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
            HStack {
                Text("Event log")
                Spacer()
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
