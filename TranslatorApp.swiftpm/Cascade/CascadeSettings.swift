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

    private var voicesObserver: NSObjectProtocol?

    init() {
        // Voice availability is not stable (downloads, deletions, storage
        // purges) — refresh the card live when the inventory changes.
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let voicesObserver {
            NotificationCenter.default.removeObserver(voicesObserver)
        }
    }

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
        // Source options (§8.1): STT-supported locales ∩ translation-
        // supported languages, deduped to language(+script for zh) codes.
        // Locale.Language does the code work — a naive prefix(2) mangles
        // 3-letter codes (yue_CN → "yu") and collapses zh-Hans/zh-Hant.
        let supported = await SpeechTranscriber.supportedLocales
        let translatable = Set(
            await LanguageAvailability().supportedLanguages
                .compactMap { $0.languageCode?.identifier }
        )
        var seen = Set<String>()
        var options: [String] = []
        for locale in supported {
            let language = Locale.Language(identifier: locale.identifier(.bcp47))
            guard let base = language.languageCode?.identifier else { continue }
            let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier
            let code = base == "zh" ? "zh-\(script ?? "Hans")" : base
            guard !seen.contains(code), translatable.isEmpty || translatable.contains(base) else { continue }
            seen.insert(code)
            options.append(code)
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
    // EVERYTHING here is lazy: this object is an @State initial value, so
    // SwiftUI constructs (and discards) instances on Settings re-renders —
    // an AVAudioEngine built in init would churn audio-system plumbing at
    // render frequency for a player that usually never plays.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var synth: AppleSpeechSynth?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
    )!

    func play(voiceIdentifier: String, language: String, rate: Double) {
        stop()
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.player = player
        }
        guard let engine, let player = self.player else { return }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        // play() on a stopped engine raises an ObjC exception — a failed
        // start (session contention, interruption) must degrade to a
        // silent no-op, not a crash.
        guard engine.isRunning else {
            Log.warn("Voice preview: audio engine failed to start — preview skipped")
            return
        }
        player.play()
        let boundPlayer = player
        let synth = AppleSpeechSynth(lane: 99, voiceIdentifier: voiceIdentifier, rate: rate, languageHint: language)
        self.synth = synth
        synth.onAudio = { [weak self] _, data in
            DispatchQueue.main.async {
                guard let self,
                      let buffer = EngineGraph.pcm16ToFloatBuffer(data, format: self.format) else { return }
                boundPlayer.scheduleBuffer(buffer, completionHandler: nil)
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
        player?.stop()
        // Don't leave hardware IO running for the life of the Settings
        // view once the sample ends.
        if engine?.isRunning == true { engine?.stop() }
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
    @AppStorage(AppSettings.cascadeTranslationProviderKey) private var translationProviderRaw = AppSettings.CascadeTranslationProvider.apple.rawValue
    // Defaulted in the @AppStorage itself (not onAppear-materialized like
    // SettingsView's) so the Picker's selection matches a tag on the very
    // first render — review NIT.
    @AppStorage(AppSettings.cascadeTranslationModelKey) private var translationModel = AppSettings.defaultCascadeTranslationModel
    @AppStorage(AppSettings.cascadeTranslationPriorityKey) private var translationPriority = false
    @AppStorage(AppSettings.cascadeSTTProviderKey) private var sttProviderRaw = AppSettings.CascadeSTTProvider.apple.rawValue
    @AppStorage(AppSettings.dashScopeRegionKey) private var dashScopeRegionRaw = AppSettings.DashScopeRegion.beijing.rawValue
    @State private var dashScopeKey: String = KeychainStore.loadDashScopeKey() ?? ""
    @State private var dashScopeKeySaved = false

    @StateObject private var setup = CascadeSetupModel()
    @State private var preview = VoicePreviewPlayer()
    @State private var packConfig: TranslationSession.Configuration?
    /// Bumped to re-resolve lane voice choices after edits/downloads.
    @State private var voiceRefresh = 0
    /// MT model picker source — fetched from /v1/models like the
    /// prompter's picker; the static list covers fetch failure/no key.
    @State private var availableModels: [String] = []
    @State private var modelsNote: String?

    private static let fallbackModels = [
        "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini"
    ]

    private var pipeline: AppSettings.Pipeline {
        AppSettings.Pipeline(rawValue: pipelineRaw) ?? .realtime
    }

    private var translationProvider: AppSettings.CascadeTranslationProvider {
        AppSettings.CascadeTranslationProvider(rawValue: translationProviderRaw) ?? .apple
    }

    private var sttProvider: AppSettings.CascadeSTTProvider {
        AppSettings.CascadeSTTProvider(rawValue: sttProviderRaw) ?? .apple
    }

    var body: some View {
        Section {
            Picker("Pipeline", selection: $pipelineRaw) {
                ForEach(AppSettings.Pipeline.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            if pipeline == .cascade {
                Picker("Speech recognition", selection: $sttProviderRaw) {
                    ForEach(AppSettings.CascadeSTTProvider.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                if sttProvider == .funasr {
                    // Reachability/auth are probed at Start (readiness);
                    // the card only asserts what it can check statically.
                    dashScopeKeyRow
                    Picker("DashScope region", selection: $dashScopeRegionRaw) {
                        ForEach(AppSettings.DashScopeRegion.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                } else {
                    statusRow("Speech recognition", status: setup.sttStatus) {
                        Button(setup.downloading ? "Downloading…" : "Download") { setup.downloadSTT() }
                            .disabled(setup.downloading)
                    }
                }
                // With OpenAI MT selected the pack is the per-job OFFLINE
                // FALLBACK (§14.4): still downloadable here, because a
                // user who never installed it must not discover that as
                // "—" on every outage.
                statusRow(translationProvider == .openai ? "Offline fallback pack" : "Translation pack",
                          status: setup.translationStatus) {
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
                Picker("Translation", selection: $translationProviderRaw) {
                    ForEach(AppSettings.CascadeTranslationProvider.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                if translationProvider == .openai {
                    keyStatusRow
                    Picker("Translation model", selection: $translationModel) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    if let modelsNote {
                        Text(modelsNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Deliberately separate from the prompter's priority
                    // toggle: translation latency is heard in the ear on
                    // every sentence, so its spend knob is its own.
                    Toggle("Priority processing (≈2× token price)", isOn: $translationPriority)
                }
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
                    // AVSpeechUtterance.rate is a normalized 0–1 value,
                    // so this multiplier is NOT a linear speed factor —
                    // label it qualitatively and let the preview button
                    // be the judge.
                    Text("Speech rate")
                        .font(.callout)
                    HStack {
                        Text("slower").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $speechRate, in: 0.7...1.5, step: 0.05)
                        Text("faster").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Translation pipeline")
        } footer: {
            Text(cascadeFooter)
        }
        .onAppear { setup.refresh() }
        .task(id: translationProviderRaw) {
            if translationProvider == .openai { await loadModels() }
        }
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

    private var cascadeFooter: String {
        guard pipeline == .cascade else {
            return "Realtime (OpenAI) translates while people speak (~0.5–1.5 s, per-minute billing, needs the API key and network). The on-device cascade is free and offline-capable with a distinct voice per speaker. Applies at the next Start."
        }
        let sttNote = sttProvider == .funasr
            ? "Recognition uses Alibaba Fun-ASR (cloud) — built for Chinese dialects including Jin (晋语, the Datong area); needs the DashScope key and network, billed per second of speech. "
            : ""
        if translationProvider == .openai {
            return "\(sttNote)Cascade with OpenAI translation: \(sttProvider == .funasr ? "voices stay" : "recognition and voices stay") on-device; translation uses the chat model with recent-conversation context (per-token billing, needs the API key and network — falls back to the Apple pack per sentence when unreachable). Applies at the next Start. \(AppleTTSProvider.voiceDownloadHint)"
        }
        if sttProvider == .funasr {
            return "\(sttNote)Translation and voices stay on-device. Applies at the next Start. \(AppleTTSProvider.voiceDownloadHint)"
        }
        return "On-device: free, works offline once the model, pack, and voices are downloaded, and each speaker gets their own voice. Speech-end → translated audio runs ~1–2 s (the realtime pipeline translates mid-speech). Applies at the next Start. \(AppleTTSProvider.voiceDownloadHint)"
    }

    /// Fetched list first, static fallback otherwise; the current
    /// selection is always present so the picker never shows an
    /// unselectable state.
    private var modelChoices: [String] {
        var choices = availableModels.isEmpty ? Self.fallbackModels : availableModels
        let current = translationModel.isEmpty ? AppSettings.defaultCascadeTranslationModel : translationModel
        if !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    private func loadModels() async {
        guard availableModels.isEmpty else { return }
        guard let key = KeychainStore.loadAPIKey(), !key.isEmpty else {
            modelsNote = "Add an API key to list your account's models — showing common ones."
            return
        }
        do {
            let models = try await ChatCompletionClient.listModels(apiKey: key)
            if !models.isEmpty {
                availableModels = models
                modelsNote = nil
            }
        } catch {
            modelsNote = "Couldn't fetch your model list — showing common models."
            Log.warn("[cascade] model list fetch failed: \(error.localizedDescription)")
        }
    }

    /// DashScope key for the Fun-ASR STT stage, stored in the Keychain
    /// like the OpenAI key (SettingsView's idiom). Saved explicitly, not
    /// per keystroke.
    @ViewBuilder
    private var dashScopeKeyRow: some View {
        HStack {
            SecureField("DashScope API key (sk-…)", text: $dashScopeKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(dashScopeKeySaved ? "Saved ✓" : "Save") {
                KeychainStore.saveDashScopeKey(dashScopeKey.trimmingCharacters(in: .whitespacesAndNewlines))
                dashScopeKeySaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dashScopeKeySaved = false }
            }
            .disabled(dashScopeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Key presence for the OpenAI MT stage (§14.1: the key is required
    /// at Start again once any OpenAI stage is selected).
    @ViewBuilder
    private var keyStatusRow: some View {
        let hasKey = !(KeychainStore.loadAPIKey() ?? "").isEmpty
        HStack {
            Label("API key", systemImage: hasKey ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(hasKey ? Color.green : Color.red)
            Spacer()
            Text(hasKey ? "saved" : "required — add it in Settings → OpenAI")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
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
        // previewAssignment, not voice(for:): SwiftUI body evaluation
        // must not write UserDefaults (the persist happens on explicit
        // selection here, or on the engine path at Start).
        let currentID = AppleTTSProvider.previewAssignment(for: channel, language: outputLanguage)?.identifier
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
