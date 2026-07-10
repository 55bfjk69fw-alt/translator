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
    @AppStorage("speakerEnabled0") private var speakerEnabled0 = true
    @AppStorage("speakerEnabled1") private var speakerEnabled1 = true
    @AppStorage("speakerEnabled2") private var speakerEnabled2 = true
    @AppStorage("speakerEnabled3") private var speakerEnabled3 = true
    @AppStorage(AppSettings.modelNameKey) private var modelName = ""
    @AppStorage(AppSettings.endpointTemplateKey) private var endpointTemplate = ""
    @AppStorage(AppSettings.idleCloseSecondsKey) private var idleCloseSeconds = 120.0
    @AppStorage(AppSettings.showPinyinKey) private var showPinyin = true
    @AppStorage(AppSettings.outputGainKey) private var outputGain = 1.0

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
                    .onChange(of: outputGain) { newValue in
                        model.setOutputGain(Float(newValue))
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Volume of translated audio, on top of the iPad's hardware volume. Above 100% is a digital boost for loud rooms — the very top of the range can distort. Takes effect immediately.")
                }

                Section {
                    Toggle("Auto-play my Chinese over speaker", isOn: $autoPlayChinese)
                } header: {
                    Text("Push to talk")
                } footer: {
                    Text("Off: your translated Chinese appears as text with a play button. On: it plays over the iPad speaker as soon as it arrives.")
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
                } header: {
                    Text("Signal quality")
                } footer: {
                    Text("The gate learns each channel's noise floor automatically and opens when speech rises above it; the slider sets the quietest level it will ever open at. When several mics pick up the same voice, only the loudest copy is sent — people genuinely talking at the same time all pass. Also enable each transmitter's onboard noise cancelling (Basic/Strong) from the DJI receiver.")
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
