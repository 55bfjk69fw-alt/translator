import SwiftUI
import Translation

/// Diagnostics section for the CP0 cascade probe
/// (docs/CASCADE-PIPELINE.md §10). Also hosts the app's only
/// download-capable TranslationSession: language-pack downloads need a
/// visible `.translationTask` view (the system consent/progress sheet
/// anchors to it), and this section doubles as the prototype for the
/// setup card's download row.
struct CascadeProbeSection: View {
    @ObservedObject var probe: CascadeProbe
    /// Setting a configuration fires the translationTask action below —
    /// that session CAN request downloads, unlike the probe's headless ones.
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var downloadStatus: String?

    var body: some View {
        Section {
            if probe.running {
                HStack {
                    ProgressView()
                    Text(probe.stage ?? "running…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .destructive) { probe.cancel() }
            } else {
                Button("Run cascade probe (all steps, no API cost)") { probe.runAll() }
                HStack {
                    Stepper("Sustained run: \(probe.sustainedMinutes) min", value: $probe.sustainedMinutes, in: 1...60)
                        .font(.callout)
                }
                Button("Run sustained-load test") { probe.runSustained() }
            }

            // Asset downloads — the two mechanisms the setup card will use.
            Button("Download STT model (中文, no sheet)") { probe.downloadSTTAssets() }
                .disabled(probe.running)
            if let status = probe.sttDownloadStatus {
                Text("STT assets: \(status)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("Download translation pack (中文→English, system sheet)") {
                downloadStatus = "requesting…"
                downloadConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "zh-Hans"),
                    target: Locale.Language(identifier: "en")
                )
            }
            .disabled(probe.running)
            .translationTask(downloadConfig) { session in
                do {
                    try await session.prepareTranslation()
                    downloadStatus = "pack installed"
                } catch {
                    downloadStatus = "failed/dismissed: \(error.localizedDescription)"
                }
            }
            if let downloadStatus {
                Text("Translation pack: \(downloadStatus)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !probe.lines.isEmpty {
                DisclosureGroup("Probe log (\(probe.lines.count))") {
                    ForEach(Array(probe.lines.enumerated().reversed()), id: \.offset) { _, line in
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
        } header: {
            Text("Cascade probe (on-device STT · translation · TTS)")
        } footer: {
            Text("Validates the cascade pipeline design's unverified claims on this iPad before implementation (docs/CASCADE-PIPELINE.md §10): the iOS 26 frameworks inside Swift Playgrounds, how many concurrent Mandarin speech analyzers the device admits, whether two TTS renders overlap, Chinese punctuation in transcripts, and on-device translation latency. Test audio is synthesized on-device — no mic, no API key. Requires the 中文 STT model and the 中文→English translation pack (buttons above; the translation download shows a system sheet). Share the log either way — the results go in the design doc.")
        }
    }
}
