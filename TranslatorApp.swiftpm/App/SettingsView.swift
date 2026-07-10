import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    @State private var keySaved = false

    @AppStorage(AppSettings.autoPlayChineseKey) private var autoPlayChinese = false
    @AppStorage(AppSettings.noiseGateEnabledKey) private var noiseGateEnabled = true
    @AppStorage(AppSettings.neuralVADEnabledKey) private var neuralVADEnabled = true
    @AppStorage(AppSettings.micProfileKey) private var micProfileRaw = AppSettings.MicProfile.worn.rawValue
    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage("speakerName0") private var speakerName0 = ""
    @AppStorage("speakerName1") private var speakerName1 = ""
    @AppStorage("speakerName2") private var speakerName2 = ""
    @AppStorage("speakerName3") private var speakerName3 = ""
    @AppStorage("speakerEnabled0") private var speakerEnabled0 = true
    @AppStorage("speakerEnabled1") private var speakerEnabled1 = true
    @AppStorage("speakerEnabled2") private var speakerEnabled2 = true
    @AppStorage("speakerEnabled3") private var speakerEnabled3 = true
    @AppStorage(AppSettings.modelNameKey) private var modelName = ""
    @AppStorage(AppSettings.endpointTemplateKey) private var endpointTemplate = ""
    @AppStorage(AppSettings.idleCloseSecondsKey) private var idleCloseSeconds = 120.0
    @AppStorage(AppSettings.showPinyinKey) private var showPinyin = true
    @AppStorage(AppSettings.outputGainKey) private var outputGain = 1.0
    @AppStorage(AppSettings.outputLanguageKey) private var outputLanguage = "en"
    @AppStorage(AppSettings.pttOutputLanguageKey) private var pttOutputLanguage = "zh"

    private var micProfile: AppSettings.MicProfile {
        AppSettings.MicProfile(rawValue: micProfileRaw) ?? .worn
    }

    private struct LanguageOption: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// The gpt-realtime-translate output languages confirmed in OpenAI's docs
    /// (the model supports 13; input is auto-detected from 70+ regardless).
    private static let outputLanguages: [LanguageOption] = [
        LanguageOption(code: "en", name: "English"),
        LanguageOption(code: "zh", name: "Chinese (Mandarin)"),
        LanguageOption(code: "es", name: "Spanish"),
        LanguageOption(code: "fr", name: "French"),
        LanguageOption(code: "de", name: "German"),
        LanguageOption(code: "it", name: "Italian"),
        LanguageOption(code: "pt", name: "Portuguese"),
        LanguageOption(code: "ja", name: "Japanese"),
        LanguageOption(code: "ko", name: "Korean"),
        LanguageOption(code: "ar", name: "Arabic")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI") {
                    SecureField("API key (sk-…)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(keySaved ? "Saved ✓" : "Save key to Keychain") {
                        KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        keySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    speakerRow("Speaker 1 (TX1)", name: $speakerName0, enabled: $speakerEnabled0)
                    speakerRow("Speaker 2 (TX2)", name: $speakerName1, enabled: $speakerEnabled1)
                    speakerRow("Speaker 3 (TX3)", name: $speakerName2, enabled: $speakerEnabled2)
                    speakerRow("Speaker 4 (TX4)", name: $speakerName3, enabled: $speakerEnabled3)
                    TextField("Your name", text: $userName)
                } header: {
                    Text("Speakers")
                } footer: {
                    Text("Switch off any transmitter you aren't using: its channel is muted and never opens a translation session. Takes effect immediately, even mid-conversation.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Output volume: \(Int((outputGain * 100).rounded()))%")
                            .font(.callout)
                        HStack {
                            Image(systemName: "speaker.wave.1")
                                .foregroundStyle(.secondary)
                            Slider(value: $outputGain, in: 0.25...2.0, step: 0.05)
                            Image(systemName: "speaker.wave.3")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: outputGain) { _, newValue in
                        model.setOutputGain(Float(newValue))
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Volume of translated audio, on top of the iPad's hardware volume. Above 100% is a digital boost for loud rooms — the very top of the range can distort. Takes effect immediately.")
                }

                if #available(iOS 26.0, *) {
                    PipelineSection()
                    VoiceSection()
                }

                Section {
                    Picker("Speakers translate to", selection: $outputLanguage) {
                        ForEach(Self.outputLanguages) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    Picker("My speech translates to", selection: $pttOutputLanguage) {
                        ForEach(Self.outputLanguages) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("What anyone says is auto-detected (70+ languages) — these choose the translated output: the first for the table mics, the second for push-to-talk. Changes apply when a lane's next session opens (after an idle close, or on the next Start).")
                }

                Section {
                    Toggle("Auto-play my translation over speaker", isOn: $autoPlayChinese)
                } header: {
                    Text("Push to talk")
                } footer: {
                    Text("Off: your translated speech appears as text with a play button. On: it plays over the iPad speaker as soon as it arrives.")
                }

                Section {
                    Toggle("Show pinyin under Chinese text", isOn: $showPinyin)
                } header: {
                    Text("Transcript")
                } footer: {
                    Text("Tone-marked pinyin generated on-device. Heteronyms (多音字) occasionally get the wrong reading.")
                }

                Section {
                    Picker("Mic placement", selection: $micProfileRaw) {
                        ForEach(AppSettings.MicProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile.rawValue)
                        }
                    }
                    .onChange(of: micProfileRaw) { model.applyGateTuning() }
                    // Re-apply to the live gate on change, matching the
                    // Signal tab's tuning panel — without this the toggles
                    // only took effect at the next Start.
                    Toggle("Cross-channel noise gate", isOn: $noiseGateEnabled)
                        .onChange(of: noiseGateEnabled) { model.applyGateTuning() }
                    Toggle("Neural voice detection", isOn: $neuralVADEnabled)
                        .onChange(of: neuralVADEnabled) { model.applyGateTuning() }
                    // Rebuilt (fresh @AppStorage keys) when the profile
                    // changes so the controls edit the active profile.
                    ProfileSignalControls(profile: micProfile)
                        .id(micProfileRaw)
                } header: {
                    Text("Signal quality")
                } footer: {
                    Text("Mic placement picks the tuning profile: \"Worn on speakers\" is the original setup (a lav on each speaker's chest — faint far-away speech is treated as bleed and suppressed); \"Ambient (carried)\" is for walking around with a mic on your own chest or in hand, listening to conversations near you — quiet far-field speech is the signal, so the gate opens far lower and OpenAI's far-field noise reduction is used. Each profile remembers its own tuning; switching back restores the other exactly. Neural voice detection (Silero VAD, on-device) opens the gate on speech and ignores rustle, bumps, and room noise; turn it off to fall back to a level-based gate that learns each channel's noise floor. The slider sets the quietest level the gate will ever open at in either mode. When several mics pick up the same voice, only the loudest copy is sent — with a chest + hand pair this is what deduplicates them. Server noise reduction is applied by OpenAI before translating and applies when a lane's next session opens.")
                }

                Section {
                    Picker("Close idle sessions after", selection: $idleCloseSeconds) {
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("Never").tag(0.0)
                    }
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("Translation sessions open when a mic first picks up speech and close after this much silence (they reopen instantly on the next speech). Disconnected or powered-off transmitters never open a session.")
                }

                Section {
                    TextField("Model", text: $modelName, prompt: Text("gpt-realtime-translate"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Endpoint template", text: $endpointTemplate, prompt: Text(SessionConfig.defaultEndpointTemplate))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Only change these if OpenAI renames the model or moves the realtime translation endpoint. %@ in the template is replaced by the model name. Applies on the next Start.")
                }

                Section {
                    Button("Clear transcript", role: .destructive) {
                        model.transcript.clear()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func speakerRow(_ placeholder: String, name: Binding<String>, enabled: Binding<Bool>) -> some View {
        HStack {
            TextField(placeholder, text: name)
                .opacity(enabled.wrappedValue ? 1 : 0.4)
            Toggle(placeholder, isOn: enabled)
                .labelsHidden()
        }
    }
}

/// Pipeline mode + per-stage provider mixer for the staged pipeline.
/// iOS 26-only: the staged pipeline's on-device STT requires SpeechAnalyzer
/// (and AppSettings.pipelineMode clamps to realtime below that anyway).
@available(iOS 26.0, *)
private struct PipelineSection: View {
    @AppStorage(AppSettings.pipelineModeKey) private var pipelineModeRaw = AppSettings.PipelineMode.realtime.rawValue
    @AppStorage(AppSettings.translationProviderKey) private var translationProviderRaw = AppSettings.TranslationProvider.openAIText.rawValue
    @AppStorage(AppSettings.ttsProviderKey) private var ttsProviderRaw = AppSettings.TTSProvider.onDevice.rawValue
    @AppStorage(AppSettings.textModelNameKey) private var textModelName = ""
    @AppStorage(AppSettings.stagedSourceLanguageKey) private var stagedSourceLanguage = "zh-CN"
    @AppStorage(AppSettings.userSpokenLanguageKey) private var userSpokenLanguage = "en-US"

    private var isStaged: Bool { pipelineModeRaw == AppSettings.PipelineMode.staged.rawValue }
    private var translationProvider: AppSettings.TranslationProvider {
        AppSettings.TranslationProvider(rawValue: translationProviderRaw) ?? .openAIText
    }

    /// Spoken-language roster for on-device STT, mirroring the output
    /// languages the app already offers (BCP-47 with region, which is what
    /// SpeechTranscriber's locale matching expects).
    private static let sourceLocales: [(code: String, name: String)] = [
        ("zh-CN", "Chinese (Mandarin, Simplified)"),
        ("zh-TW", "Chinese (Mandarin, Traditional)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("ar-SA", "Arabic")
    ]

    var body: some View {
        Section {
            Picker("Translation pipeline", selection: $pipelineModeRaw) {
                ForEach(AppSettings.PipelineMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            if isStaged {
                Picker("Translate with", selection: $translationProviderRaw) {
                    ForEach(AppSettings.TranslationProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                if translationProvider == .openAIText {
                    TextField("Text model", text: $textModelName, prompt: Text("gpt-5.1"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Picker("Speech output", selection: $ttsProviderRaw) {
                    ForEach(AppSettings.TTSProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                Picker("Speakers speak", selection: $stagedSourceLanguage) {
                    ForEach(Self.sourceLocales, id: \.code) { locale in
                        Text(locale.name).tag(locale.code)
                    }
                }
                Picker("I speak", selection: $userSpokenLanguage) {
                    ForEach(Self.sourceLocales, id: \.code) { locale in
                        Text(locale.name).tag(locale.code)
                    }
                }
            }
        } header: {
            Text("Pipeline")
        } footer: {
            Text(isStaged
                 ? "Staged mode transcribes speech on this iPad (Apple's on-device recognizer — the spoken languages must be declared above, unlike Realtime's auto-detect), then translates finished sentences with the selected provider, then speaks them with the selected voice. Speech models download on first use. OpenAI translation is the quality pick; the Apple options run entirely on-device. Provider changes apply on the next Start. Costs shown for staged mode are estimates."
                 : "Realtime translates continuously over one OpenAI session per speaker (~0.5–1.5 s behind, $0.034/min per active speaker). Staged mode splits the work into on-device speech recognition, a translation model of your choice, and a voice of your choice — cheaper, often better translations, at the cost of waiting for whole sentences.")
        }
    }
}

/// Per-lane voice pickers for the staged TTS stage: one row per enabled
/// speaker plus "My voice" (the PTT lane), each with a preview button.
/// Auto (distinct) rotates every lane onto a different voice; explicit
/// picks win. Hidden unless the staged pipeline with a voice is selected.
@available(iOS 26.0, *)
private struct VoiceSection: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var preview = VoicePreviewController()

    @AppStorage(AppSettings.pipelineModeKey) private var pipelineModeRaw = AppSettings.PipelineMode.realtime.rawValue
    @AppStorage(AppSettings.ttsProviderKey) private var ttsProviderRaw = AppSettings.TTSProvider.onDevice.rawValue
    @AppStorage(AppSettings.outputLanguageKey) private var outputLanguage = "en"
    @AppStorage(AppSettings.pttOutputLanguageKey) private var pttOutputLanguage = "zh"
    // Live bindings to the Speakers section above, so renames/disables
    // update the voice rows immediately.
    @AppStorage("speakerName0") private var speakerName0 = ""
    @AppStorage("speakerName1") private var speakerName1 = ""
    @AppStorage("speakerName2") private var speakerName2 = ""
    @AppStorage("speakerName3") private var speakerName3 = ""
    @AppStorage("speakerEnabled0") private var speakerEnabled0 = true
    @AppStorage("speakerEnabled1") private var speakerEnabled1 = true
    @AppStorage("speakerEnabled2") private var speakerEnabled2 = true
    @AppStorage("speakerEnabled3") private var speakerEnabled3 = true

    private var isStaged: Bool { pipelineModeRaw == AppSettings.PipelineMode.staged.rawValue }
    private var ttsProvider: AppSettings.TTSProvider {
        AppSettings.TTSProvider(rawValue: ttsProviderRaw) ?? .onDevice
    }
    private var speakerNames: [String] { [speakerName0, speakerName1, speakerName2, speakerName3] }
    private var speakersEnabled: [Bool] { [speakerEnabled0, speakerEnabled1, speakerEnabled2, speakerEnabled3] }

    var body: some View {
        if isStaged, ttsProvider != .none {
            // Enumerating the voice registry per body evaluation is fine
            // here (Settings, not a hot path); one list per language keeps
            // the rows from each doing it. The exclusion set mirrors the
            // runtime rotation rule (auto lanes skip explicit picks) so
            // previews play exactly what a lane would.
            let speakerRoster = OnDeviceSynthesizer.installedVoices(for: outputLanguage)
            let userRoster = OnDeviceSynthesizer.installedVoices(for: pttOutputLanguage)
            let voiceLanes = [0, 1, 2, 3, SpeakerLane.userLaneID]
            let excludedVoices: Set<String> = ttsProvider == .onDevice
                ? Set(voiceLanes.map { AppSettings.onDeviceVoiceSetting(lane: $0) }.filter { !$0.isEmpty })
                : Set(voiceLanes.map { AppSettings.openAIVoiceSetting(lane: $0) }.filter { !$0.isEmpty })
            Section {
                ForEach(0..<4, id: \.self) { channel in
                    if speakersEnabled[channel] {
                        VoiceRow(
                            label: speakerNames[channel].isEmpty ? "Speaker \(channel + 1)" : speakerNames[channel],
                            storageKey: ttsProvider == .onDevice
                                ? AppSettings.speakerVoiceOnDeviceKey(channel)
                                : AppSettings.speakerVoiceOpenAIKey(channel),
                            laneIndex: channel,
                            languageCode: outputLanguage,
                            provider: ttsProvider,
                            ttsModel: AppSettings.openAITTSModel,
                            appIsIdle: model.mode == .idle,
                            onDeviceRoster: speakerRoster,
                            excludedVoices: excludedVoices,
                            preview: preview
                        )
                        .id("voice-\(channel)-\(ttsProviderRaw)-\(outputLanguage)")
                    }
                }
                VoiceRow(
                    label: "My voice",
                    storageKey: ttsProvider == .onDevice
                        ? AppSettings.userVoiceOnDeviceKey
                        : AppSettings.userVoiceOpenAIKey,
                    laneIndex: 4,
                    languageCode: pttOutputLanguage,
                    provider: ttsProvider,
                    ttsModel: AppSettings.openAITTSModel,
                    appIsIdle: model.mode == .idle,
                    onDeviceRoster: userRoster,
                    excludedVoices: excludedVoices,
                    preview: preview
                )
                .id("voice-user-\(ttsProviderRaw)-\(pttOutputLanguage)")
                if let error = preview.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Voices")
            } footer: {
                Text(ttsProvider == .onDevice
                     ? "With Auto, each speaker gets a different on-device voice so you can tell them apart by ear; your picks override. Extra voices install under iPadOS Settings → Accessibility → Spoken Content. Voice changes apply on the next Start."
                     : "With Auto, each speaker gets a different OpenAI voice so you can tell them apart by ear; your picks override. Each preview makes a small paid TTS request (a fraction of a cent, not counted in the conversation estimate). Voice changes apply on the next Start.")
            }
            // Deliberately no onDisappear stop: Form sections fire it on
            // scroll-out, which would cut previews mid-sample; previews are
            // a few seconds and self-terminate. Provider/language switches
            // DO stop them — the rows rebuild and would orphan the audio
            // with no stop button.
            .onChange(of: ttsProviderRaw) { preview.stop() }
            .onChange(of: outputLanguage) { preview.stop() }
            .onChange(of: pttOutputLanguage) { preview.stop() }
        }
    }
}

/// One voice picker + preview button, bound to the lane's storage key.
@available(iOS 26.0, *)
private struct VoiceRow: View {
    let label: String
    let laneIndex: Int
    let languageCode: String
    let provider: AppSettings.TTSProvider
    let ttsModel: String
    let appIsIdle: Bool
    let onDeviceRoster: [AVSpeechSynthesisVoice]
    let excludedVoices: Set<String>
    @ObservedObject var preview: VoicePreviewController

    @AppStorage private var voiceID: String
    private let rowID: String

    init(label: String, storageKey: String, laneIndex: Int, languageCode: String,
         provider: AppSettings.TTSProvider, ttsModel: String,
         appIsIdle: Bool, onDeviceRoster: [AVSpeechSynthesisVoice],
         excludedVoices: Set<String>, preview: VoicePreviewController) {
        self.label = label
        self.laneIndex = laneIndex
        self.languageCode = languageCode
        self.provider = provider
        self.ttsModel = ttsModel
        self.appIsIdle = appIsIdle
        self.onDeviceRoster = onDeviceRoster
        self.excludedVoices = excludedVoices
        self.preview = preview
        self.rowID = storageKey
        _voiceID = AppStorage(wrappedValue: "", storageKey)
    }

    private var isPlaying: Bool { preview.activeRowID == rowID }

    /// A stored pick that isn't in the current roster (voice uninstalled,
    /// language switched) displays as Auto WITHOUT clobbering storage —
    /// matching the runtime resolver's fallback; picking anything writes a
    /// valid value again.
    private var safeSelection: Binding<String> {
        let known: Set<String> = provider == .onDevice
            ? Set(onDeviceRoster.map(\.identifier)).union([""])
            : Set(OpenAISynthesizer.voiceRoster).union([""])
        return Binding(
            get: { known.contains(voiceID) ? voiceID : "" },
            set: { voiceID = $0 }
        )
    }

    var body: some View {
        HStack {
            Picker(label, selection: safeSelection) {
                Text("Auto (distinct)").tag("")
                if provider == .onDevice {
                    ForEach(onDeviceRoster, id: \.identifier) { voice in
                        Text(displayName(voice)).tag(voice.identifier)
                    }
                } else {
                    ForEach(OpenAISynthesizer.voiceRoster, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                }
            }
            // Borderless so the tap doesn't hijack the whole Form row.
            // Always enabled: a missing API key surfaces as the section's
            // error text on tap (a disabled flag here goes stale when the
            // key is saved in the section above without this view leaving
            // the screen).
            Button {
                togglePreview()
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Stop preview" : "Preview \(label) voice")
        }
    }

    private func togglePreview() {
        if isPlaying {
            preview.stop()
            return
        }
        let explicit = voiceID.isEmpty ? nil : voiceID
        switch provider {
        case .onDevice:
            preview.previewOnDevice(rowID: rowID, explicitVoiceID: explicit,
                                    laneIndex: laneIndex, languageCode: languageCode,
                                    excludedVoices: excludedVoices, appIsIdle: appIsIdle)
        case .openAI:
            preview.previewOpenAI(rowID: rowID, explicitVoice: explicit,
                                  laneIndex: laneIndex, languageCode: languageCode,
                                  model: ttsModel, excludedVoices: excludedVoices,
                                  appIsIdle: appIsIdle)
        case .none:
            break
        }
    }

    private func displayName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .enhanced: return "\(voice.name) (Enhanced)"
        case .premium: return "\(voice.name) (Premium)"
        default: return voice.name
        }
    }
}

/// The per-profile signal settings, bound to the given profile's storage
/// keys. Instantiate with `.id(profile)` so a profile switch rebuilds the
/// @AppStorage bindings against the new keys.
private struct ProfileSignalControls: View {
    @EnvironmentObject private var model: AppModel

    let profile: AppSettings.MicProfile
    @AppStorage private var vadThreshold: Double
    @AppStorage private var noiseReduction: String

    init(profile: AppSettings.MicProfile) {
        self.profile = profile
        let defaults = AppSettings.gateDefaults(for: profile)
        _vadThreshold = AppStorage(
            wrappedValue: defaults.vadThreshold,
            AppSettings.profileKey(AppSettings.vadThresholdKey, profile)
        )
        _noiseReduction = AppStorage(
            wrappedValue: defaults.noiseReduction,
            AppSettings.profileKey(AppSettings.noiseReductionKey, profile)
        )
    }

    var body: some View {
        Group {
            VStack(alignment: .leading) {
                // Far-field speech sits well below the worn range, so the
                // ambient slider covers a lower decade at finer print.
                Text(String(format: profile == .worn ? "Minimum voice threshold: %.3f" : "Minimum voice threshold: %.4f", vadThreshold))
                    .font(.callout)
                Slider(value: $vadThreshold, in: profile == .worn ? 0.002...0.05 : 0.0005...0.01)
                    .onChange(of: vadThreshold) { model.applyGateTuning() }
            }
            Picker("Server noise reduction", selection: $noiseReduction) {
                Text("Near field (lav mics)").tag("near_field")
                Text("Far field (room mics)").tag("far_field")
                Text("Off").tag("off")
            }
        }
    }
}
