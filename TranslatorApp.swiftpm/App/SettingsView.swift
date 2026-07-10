import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    @State private var keySaved = false

    @AppStorage(AppSettings.autoPlayChineseKey) private var autoPlayChinese = false
    @AppStorage(AppSettings.noiseGateEnabledKey) private var noiseGateEnabled = true
    @AppStorage(AppSettings.vadThresholdKey) private var vadThreshold = 0.004
    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage("speakerName0") private var speakerName0 = ""
    @AppStorage("speakerName1") private var speakerName1 = ""
    @AppStorage("speakerName2") private var speakerName2 = ""
    @AppStorage("speakerName3") private var speakerName3 = ""
    @AppStorage(AppSettings.modelNameKey) private var modelName = ""
    @AppStorage(AppSettings.endpointTemplateKey) private var endpointTemplate = ""
    @AppStorage(AppSettings.idleCloseSecondsKey) private var idleCloseSeconds = 120.0
    @AppStorage(AppSettings.showPinyinKey) private var showPinyin = true
    @AppStorage(AppSettings.outputLanguageKey) private var outputLanguage = "en"
    @AppStorage(AppSettings.pttOutputLanguageKey) private var pttOutputLanguage = "zh"
    @AppStorage(AppSettings.noiseReductionKey) private var noiseReduction = "near_field"

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

                Section("Speakers") {
                    TextField("Speaker 1 (TX1)", text: $speakerName0)
                    TextField("Speaker 2 (TX2)", text: $speakerName1)
                    TextField("Speaker 3 (TX3)", text: $speakerName2)
                    TextField("Speaker 4 (TX4)", text: $speakerName3)
                    TextField("Your name", text: $userName)
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
                    Toggle("Cross-channel noise gate", isOn: $noiseGateEnabled)
                    VStack(alignment: .leading) {
                        Text(String(format: "Minimum voice threshold: %.3f", vadThreshold))
                            .font(.callout)
                        Slider(value: $vadThreshold, in: 0.002...0.05)
                    }
                    Picker("Server noise reduction", selection: $noiseReduction) {
                        Text("Near field (lav mics)").tag("near_field")
                        Text("Far field (room mics)").tag("far_field")
                        Text("Off").tag("off")
                    }
                } header: {
                    Text("Signal quality")
                } footer: {
                    Text("The gate learns each channel's noise floor automatically and opens when speech rises above it; the slider sets the quietest level it will ever open at. When several mics pick up the same voice, only the loudest copy is sent — people genuinely talking at the same time all pass. Also enable each transmitter's onboard noise cancelling (Basic/Strong) from the DJI receiver. Server noise reduction is applied by OpenAI before translating: near field suits the clipped-on DJI lavs, far field suits a distant mic; it applies when a lane's next session opens.")
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
}
