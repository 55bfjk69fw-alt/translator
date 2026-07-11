import SwiftUI
import UIKit

/// Signal-analysis workbench: per-channel gate timelines, a mini transcript,
/// the bleed-correlation matrix, spectrograms/spectra/waveforms for all
/// channels, and live gate tuning. Analysis only runs while this tab is
/// visible; freezing stops the displays without touching the audio pipeline.
struct SignalView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var analyzer: SignalAnalyzer

    @State private var exportJSON: String?
    @State private var exportCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // A frozen window stays inspectable/exportable even
                    // after the session that produced it has stopped.
                    if model.mode == .idle && !(analyzer.isFrozen && analyzer.snapshot.channelCount > 0) {
                        idleCard
                    } else if analyzer.snapshot.channelCount == 0 {
                        waitingCard
                    } else {
                        gateTimelineCard
                        if model.mode == .conversation {
                            miniTranscriptCard
                        }
                        correlationCard
                        channelCards
                    }
                    tuningCard
                    if analyzer.isFrozen {
                        exportCard
                    }
                }
                .padding()
            }
            .navigationTitle("Signal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    freezeButton
                }
            }
            .onAppear { analyzer.setEnabled(true) }
            .onDisappear { analyzer.setEnabled(false) }
        }
    }

    // MARK: - Controls

    private var freezeButton: some View {
        Button {
            let freezing = !analyzer.isFrozen
            analyzer.setFrozen(freezing)
            if freezing {
                let names = (0..<max(1, analyzer.snapshot.channelCount)).map { model.laneName($0) }
                analyzer.exportSnapshot(channelNames: names) { exportJSON = $0 }
            } else {
                exportJSON = nil
            }
        } label: {
            Label(
                analyzer.isFrozen ? "Resume" : "Freeze",
                systemImage: analyzer.isFrozen ? "play.circle" : "pause.circle"
            )
        }
        .disabled(model.mode == .idle && !analyzer.isFrozen)
    }

    private var idleCard: some View {
        card("Signal analysis") {
            Text("Nothing is running. Start a bench test to analyze the mics without opening any translation sessions (no API cost), or start a conversation from the Conversation tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Start bench test") {
                model.startBenchTest()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var waitingCard: some View {
        card("Signal analysis") {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for audio…")
                    .foregroundStyle(.secondary)
            }
            stopButton
        }
    }

    private var stopButton: some View {
        Button("Stop", role: .destructive) {
            model.stopConversation()
        }
    }

    // MARK: - Gate timeline

    private var gateTimelineCard: some View {
        card("Gate timeline — last \(Int(SignalAnalyzer.gateWindowSeconds)) s") {
            legend
            ForEach(0..<analyzer.snapshot.channelCount, id: \.self) { channel in
                timelineRow(channel: channel)
            }
            if model.mode == .bench {
                HStack {
                    Text("Bench mode — gate runs with real settings, nothing is sent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    stopButton
                        .font(.footnote)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Rectangle().fill(.primary).frame(width: 14, height: 3)
                Text("level")
            }
            HStack(spacing: 4) {
                Rectangle().fill(.primary.opacity(0.6)).frame(width: 14, height: 2)
                Text("threshold ┄")
            }
            HStack(spacing: 4) {
                Rectangle().fill(.secondary).frame(width: 14, height: 1.5)
                Text("noise floor ┈")
            }
            HStack(spacing: 4) {
                Rectangle().fill(.green.opacity(0.3)).frame(width: 14, height: 10)
                Text("gate open")
            }
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                Text("bleed suppressed")
            }
            HStack(spacing: 4) {
                Rectangle().fill(.indigo.opacity(0.8)).frame(width: 14, height: 6)
                Text("VAD speech probability (bottom strip)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func timelineRow(channel: Int) -> some View {
        let snapshot = analyzer.snapshot
        let lane = model.lane(for: channel)
        let last = snapshot.gate[channel].last
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(lane.color).frame(width: 8, height: 8)
                Text(lane.name)
                    .font(.caption.bold())
                Spacer()
                if let last {
                    Text("level \(dbString(last.rms))  ·  floor \(dbString(last.noiseFloor))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GateTimelineView(
                points: snapshot.gate[channel],
                elapsed: snapshot.elapsed,
                color: lane.color
            )
            .frame(height: 72)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    // MARK: - Mini transcript

    private var miniTranscriptCard: some View {
        card("Transcript") {
            if model.transcript.utterances.isEmpty {
                Text("No speech translated yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.transcript.utterances.suffix(30)) { utterance in
                                MiniTranscriptRow(
                                    utterance: utterance,
                                    lane: model.lane(for: utterance.laneID)
                                )
                                .id(utterance.id)
                            }
                        }
                    }
                    .frame(height: 150)
                    .onAppear {
                        if let last = model.transcript.utterances.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.transcript.utterances.count) {
                        if let last = model.transcript.utterances.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Correlation matrix

    private var correlationCard: some View {
        card("Mic-pair correlation") {
            CorrelationMatrixView(
                pairs: analyzer.snapshot.pairs,
                lanes: Array(model.lanes.prefix(analyzer.snapshot.channelCount)),
                threshold: analyzer.snapshot.tunables.bleedCorrelation
            )
            Text("Measured only while both mics are voiced. At or above \(String(format: "%.2f", analyzer.snapshot.tunables.bleedCorrelation)) the pair counts as one source and only the louder copy passes (red border).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-channel signal cards

    private var channelCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
            ForEach(0..<analyzer.snapshot.channelCount, id: \.self) { channel in
                channelCard(channel: channel)
            }
        }
    }

    private func channelCard(channel: Int) -> some View {
        let snapshot = analyzer.snapshot
        let lane = model.lane(for: channel)
        return card(lane.name) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spectrogram — \(Int(snapshot.sampleRate)) Hz input, 60 Hz–12 kHz log scale")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                SpectrogramView(image: channel < snapshot.spectrogramImages.count ? snapshot.spectrogramImages[channel] : nil)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Spectrum (now)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                SpectrumView(
                    bins: channel < snapshot.spectrum.count ? snapshot.spectrum[channel] : [],
                    color: lane.color
                )
                .frame(height: 64)
                HStack {
                    Text("Waveform — last 10 s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if channel < snapshot.clipCounts.count, snapshot.clipCounts[channel] > 0 {
                        Label("\(snapshot.clipCounts[channel]) clipped", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                WaveformView(
                    bins: channel < snapshot.wave.count ? snapshot.wave[channel] : [],
                    color: lane.color
                )
                .frame(height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
        }
    }

    // MARK: - Tuning

    @AppStorage(AppSettings.micProfileKey) private var micProfileRaw = AppSettings.MicProfile.worn.rawValue

    private var tuningCard: some View {
        card("Gate tuning") {
            Picker("Mic placement", selection: $micProfileRaw) {
                ForEach(AppSettings.MicProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: micProfileRaw) { model.applyGateTuning() }
            Text("Each profile keeps its own tuning — switching applies the other profile's values to the running gate within 200 ms, so you can A/B them live.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            GateTuningPanel(profile: AppSettings.MicProfile(rawValue: micProfileRaw) ?? .worn)
                .id(micProfileRaw)
        }
    }

    // MARK: - Export

    private var exportCard: some View {
        card("Frozen window export") {
            if let exportJSON {
                Text("Gate timeline, waveform envelopes, stats, and bleed events for the frozen window (\(exportJSON.count / 1024) KB JSON).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ShareLink(item: exportJSON) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(exportCopied ? "Copied ✓" : "Copy") {
                        UIPasteboard.general.string = exportJSON
                        exportCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exportCopied = false }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing export…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func dbString(_ value: Float) -> String {
        value <= 1e-5 ? "−∞ dB" : String(format: "%.0f dB", 20 * log10(value))
    }
}

// MARK: - Mini transcript row

private struct MiniTranscriptRow: View {
    let utterance: TranscriptStore.Utterance
    let lane: SpeakerLane

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(lane.color)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(lane.name)
                        .font(.caption2.bold())
                        .foregroundStyle(lane.color)
                    Text(utterance.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !utterance.isFinal {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                if !utterance.sourceText.isEmpty {
                    Text(utterance.sourceText)
                        .font(.caption)
                        .lineLimit(1)
                }
                if !utterance.translatedText.isEmpty {
                    Text(utterance.translatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Tuning panel

/// Live gate tunables for one mic profile. Sliders persist via @AppStorage
/// under the profile's keys and re-apply to the running gate on every change
/// (effective within one 200 ms buffer). Instantiate with `.id(profile)` so
/// a profile switch rebuilds the bindings against the new keys.
private struct GateTuningPanel: View {
    @EnvironmentObject private var model: AppModel

    let profile: AppSettings.MicProfile
    @AppStorage(AppSettings.noiseGateEnabledKey) private var gateEnabled = true
    @AppStorage(AppSettings.neuralVADEnabledKey) private var neuralVAD = true
    @AppStorage private var vadThreshold: Double
    @AppStorage private var vadOnProbability: Double
    @AppStorage private var snrFactor: Double
    @AppStorage private var bleedCorrelation: Double
    @AppStorage private var takeoverMargin: Double
    @AppStorage private var hangover: Double

    init(profile: AppSettings.MicProfile) {
        self.profile = profile
        let defaults = AppSettings.gateDefaults(for: profile)
        func storage(_ base: String, _ value: Double) -> AppStorage<Double> {
            AppStorage(wrappedValue: value, AppSettings.profileKey(base, profile))
        }
        _vadThreshold = storage(AppSettings.vadThresholdKey, defaults.vadThreshold)
        _vadOnProbability = storage(AppSettings.vadOnProbabilityKey, defaults.vadOnProbability)
        _snrFactor = storage(AppSettings.snrFactorKey, defaults.snrFactor)
        _bleedCorrelation = storage(AppSettings.bleedCorrelationKey, defaults.bleedCorrelation)
        _takeoverMargin = storage(AppSettings.takeoverMarginKey, defaults.takeoverMargin)
        _hangover = storage(AppSettings.gateHangoverKey, defaults.hangover)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Noise gate + bleed rejection", isOn: $gateEnabled)
            Toggle("Neural VAD voicing (Silero)", isOn: $neuralVAD)
            Text("On: an on-device speech model scores each channel (bottom strip in the timeline); the SNR factor is unused. Off: voicing falls back to level vs. the tracked noise floor.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            slider(
                "Minimum voice threshold",
                value: $vadThreshold,
                range: profile == .worn ? 0.002...0.05 : 0.0005...0.01,
                format: profile == .worn ? "%.3f" : "%.4f",
                help: "RMS below which the gate never opens, however quiet the room. The ambient profile's range sits an order of magnitude lower — far-field speech is that much quieter."
            )
            slider(
                "VAD open probability",
                value: $vadOnProbability,
                range: 0.20...0.70,
                format: "%.2f",
                help: "Silero confidence needed to open the gate (it closes 0.15 below). Lower opens on fainter/distant speech at the cost of more false opens."
            )
            slider(
                "SNR factor",
                value: $snrFactor,
                range: 1.5...6.0,
                format: "%.1f×",
                help: "How far above its noise floor a mic must rise to count as speech. Higher = fewer false opens, more clipped soft speech."
            )
            slider(
                "Bleed correlation",
                value: $bleedCorrelation,
                range: 0.30...0.90,
                format: "%.2f",
                help: "Pair similarity at which two voiced mics count as one source. Lower = more aggressive duplicate suppression; too low mutes real double-talk."
            )
            slider(
                "Takeover margin",
                value: $takeoverMargin,
                range: 1.0...2.0,
                format: "%.2f×",
                help: "How much louder a challenger must be to steal a correlated pair from the current winner (hysteresis against flip-flopping)."
            )
            slider(
                "Hangover",
                value: $hangover,
                range: 0.0...3.0,
                format: "%.1f s",
                help: "How long the gate stays open after speech, so quiet sentence endings aren't chopped."
            )
            Button("Reset \(profile == .worn ? "worn" : "ambient") profile to defaults") {
                AppSettings.resetGateTuning(profile: profile)
                model.applyGateTuning()
            }
            .font(.callout)
        }
        .onChange(of: gateEnabled) { model.applyGateTuning() }
        .onChange(of: neuralVAD) { model.applyGateTuning() }
        .onChange(of: vadThreshold) { model.applyGateTuning() }
        .onChange(of: vadOnProbability) { model.applyGateTuning() }
        .onChange(of: snrFactor) { model.applyGateTuning() }
        .onChange(of: bleedCorrelation) { model.applyGateTuning() }
        .onChange(of: takeoverMargin) { model.applyGateTuning() }
        .onChange(of: hangover) { model.applyGateTuning() }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(help)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
