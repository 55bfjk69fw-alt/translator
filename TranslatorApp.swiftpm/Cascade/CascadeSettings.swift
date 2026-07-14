import SwiftUI
import AVFoundation
import Speech
import Translation

/// Availability model behind the setup card (docs/CASCADE-PIPELINE.md
/// §8.1): one row per stage, refreshed on appear and after downloads.
@MainActor
final class CascadeSetupModel: ObservableObject {
    enum RowStatus: Equatable {
        case checking
        case ready(String)
        case needsDownload(String)
        case unsupported(String)
    }

    @Published private(set) var sttStatus: RowStatus = .checking
    @Published private(set) var translationStatus: RowStatus = .checking
    @Published private(set) var voiceStatus: RowStatus = .checking
    @Published private(set) var downloading = false
    /// STT-supported source languages (BCP-47), for the source picker —
    /// the hard constraint; the translation row reports the chosen pair.
    @Published private(set) var sourceOptions: [String] = ["zh-Hans"]

    func refresh() {
        Task { await refreshNow() }
    }

    private func refreshNow() async {
        let source = AppSettings.cascadeSourceLanguage
        let target = AppSettings.outputLanguage
        // STT row.
        let sourceLocale = Locale(identifier: source)
        if let matched = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale) {
            let installed = await SpeechTranscriber.installedLocales
            if installed.contains(where: { $0.identifier(.bcp47) == matched.identifier(.bcp47) }) {
                sttStatus = .ready("installed (\(matched.identifier))")
            } else {
                sttStatus = .needsDownload("model not downloaded")
            }
        } else {
            sttStatus = .unsupported("\(source) not supported on this device")
        }
        // Source options: dedupe supported locales down to language codes.
        let supported = await SpeechTranscriber.supportedLocales
        var seen = Set<String>()
        var options: [String] = []
        for locale in supported {
            let code = locale.identifier(.bcp47)
            let language = String(code.prefix(2))
            if !seen.contains(language) {
                seen.insert(language)
                options.append(language == "zh" ? "zh-Hans" : language)
            }
        }
        sourceOptions = options.sorted()
        // Translation row.
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed: translationStatus = .ready("pack installed")
        case .supported: translationStatus = .needsDownload("pack not downloaded")
        case .unsupported: translationStatus = .unsupported("\(source) → \(target) unsupported")
        @unknown default: translationStatus = .unsupported("unknown status")
        }
        // Voices row.
        let voices = AppleTTSProvider.voices(for: target)
        let good = voices.filter { AppleTTSProvider.rank($0) >= 2 }
        if voices.isEmpty {
            voiceStatus = .unsupported("no \(target) voices installed")
        } else if good.count < 4 {
            voiceStatus = .needsDownload("\(voices.count) voices, \(good.count) good — download enhanced voices for distinct lanes")
        } else {
            voiceStatus = .ready("\(voices.count) voices (\(good.count) good)")
        }
    }

    /// Programmatic STT model download (AssetInventory — no system sheet).
    func downloadSTT() {
        guard !downloading else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let locale = Locale(identifier: AppSettings.cascadeSourceLanguage)
                guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
                let transcriber = SpeechTranscriber(locale: matched, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                await refreshNow()
            } catch {
                sttStatus = .needsDownload("download failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Plays a short sample through the REAL synthesis path — write() →
/// convert → player node — so the preview doubles as a smoke test of the
/// exact pipeline a conversation uses (§6.4).
final class VoicePreviewPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var synth: AppleSpeechSynth?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
    )!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(voiceIdentifier: String, language: String, rate: Double) {
        stop()
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        player.play()
        let synth = AppleSpeechSynth(lane: 99, voiceIdentifier: voiceIdentifier, rate: rate)
        self.synth = synth
        synth.onAudio = { [weak self] _, data in
            DispatchQueue.main.async {
                guard let self,
                      let buffer = EngineGraph.pcm16ToFloatBuffer(data, format: self.format) else { return }
                self.player.scheduleBuffer(buffer, completionHandler: nil)
            }
        }
        let sample = language.hasPrefix("en")
            ? "Hi — I'll be this speaker's voice."
            : "你好，我是这位说话人的声音。"
        synth.synthesize(text: sample, job: UUID())
    }

    func stop() {
        synth?.cancelAll()
        synth = nil
        player.stop()
    }
}

/// Settings → Translation pipeline: the pipeline toggle, the setup card,
/// the source-language picker, per-lane voices, and the speech-rate
/// slider. Hosts the app's second (and last) download-capable
/// `.translationTask` view for the pack download.
struct CascadePipelineSection: View {
    @AppStorage(AppSettings.pipelineKey) private var pipelineRaw = AppSettings.Pipeline.realtime.rawValue
    @AppStorage(AppSettings.cascadeSourceLanguageKey) private var sourceLanguage = "zh-Hans"
    @AppStorage(AppSettings.cascadeSpeechRateKey) private var speechRate = 1.0
    @AppStorage(AppSettings.outputLanguageKey) private var outputLanguage = "en"

    @StateObject private var setup = CascadeSetupModel()
    @State private var preview = VoicePreviewPlayer()
    @State private var packConfig: TranslationSession.Configuration?
    /// Bumped to re-resolve lane voice choices after edits/downloads.
    @State private var voiceRefresh = 0

    private var pipeline: AppSettings.Pipeline {
        AppSettings.Pipeline(rawValue: pipelineRaw) ?? .realtime
    }

    var body: some View {
        Section {
            Picker("Pipeline", selection: $pipelineRaw) {
                ForEach(AppSettings.Pipeline.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            if pipeline == .cascade {
                statusRow("Speech recognition", status: setup.sttStatus) {
                    Button(setup.downloading ? "Downloading…" : "Download") { setup.downloadSTT() }
                        .disabled(setup.downloading)
                }
                statusRow("Translation pack", status: setup.translationStatus) {
                    Button("Download") {
                        if packConfig == nil {
                            packConfig = TranslationSession.Configuration(
                                source: Locale.Language(identifier: sourceLanguage),
                                target: Locale.Language(identifier: outputLanguage)
                            )
                        } else {
                            packConfig?.invalidate()
                        }
                    }
                }
                statusRow("Voices", status: setup.voiceStatus) { EmptyView() }
                Picker("Source language", selection: $sourceLanguage) {
                    ForEach(setup.sourceOptions, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                .onChange(of: sourceLanguage) { _, _ in setup.refresh() }
                ForEach(0..<4, id: \.self) { channel in
                    voiceRow(channel: channel)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Speech rate: %.2f×", speechRate))
                        .font(.callout)
                    Slider(value: $speechRate, in: 0.7...1.5, step: 0.05)
                }
            }
        } header: {
            Text("Translation pipeline")
        } footer: {
            Text(pipeline == .cascade
                 ? "On-device: free, works offline once the model, pack, and voices are downloaded, and each speaker gets their own voice. Speech-end → translated audio runs ~1–2 s (the realtime pipeline translates mid-speech). Applies at the next Start. \(AppleTTSProvider.voiceDownloadHint)"
                 : "Realtime (OpenAI) translates while people speak (~0.5–1.5 s, per-minute billing, needs the API key and network). The on-device cascade is free and offline-capable with a distinct voice per speaker. Applies at the next Start.")
        }
        .onAppear { setup.refresh() }
        .translationTask(packConfig) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                Log.warn("Translation pack download failed/dismissed: \(error.localizedDescription)")
            }
            setup.refresh()
        }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private func statusRow<Action: View>(_ title: String, status: CascadeSetupModel.RowStatus, @ViewBuilder action: () -> Action) -> some View {
        HStack {
            switch status {
            case .checking:
                Label(title, systemImage: "hourglass")
                Spacer()
                Text("checking…").font(.caption).foregroundStyle(.secondary)
            case .ready(let detail):
                Label(title, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            case .needsDownload(let detail):
                Label(title, systemImage: "arrow.down.circle").foregroundStyle(.orange)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                action()
            case .unsupported(let detail):
                Label(title, systemImage: "xmark.circle").foregroundStyle(.red)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func voiceRow(channel: Int) -> some View {
        let voices = AppleTTSProvider.voices(for: outputLanguage)
        let currentID = AppSettings.laneVoice(provider: AppleTTSProvider.id, language: outputLanguage, channel: channel)
            ?? AppleTTSProvider.voice(for: channel, language: outputLanguage)?.identifier
        HStack {
            Text("\(AppSettings.speakerName(channel)) voice")
                .font(.callout)
            Spacer()
            // id: voiceRefresh forces re-resolution after a change.
            Menu {
                ForEach(voices, id: \.identifier) { voice in
                    Button {
                        AppSettings.setLaneVoice(voice.identifier, provider: AppleTTSProvider.id, language: outputLanguage, channel: channel)
                        voiceRefresh += 1
                    } label: {
                        let quality = AppleTTSProvider.rank(voice) >= 3
                            ? " ★" : (AppleTTSProvider.rank(voice) == 0 ? " ·" : "")
                        Text("\(voice.name) (\(voice.language))\(quality)")
                    }
                }
            } label: {
                Text(voices.first(where: { $0.identifier == currentID })?.name ?? "auto")
                    .font(.callout)
            }
            .id(voiceRefresh)
            Button {
                if let id = currentID {
                    preview.play(voiceIdentifier: id, language: outputLanguage, rate: speechRate)
                }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
