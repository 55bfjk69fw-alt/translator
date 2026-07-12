import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    @State private var keySaved = false

    // Prompter model picker: fetched from the account's /v1/models at
    // view load; the static list covers fetch failure / no key yet.
    @State private var availableModels: [String] = []
    @State private var modelsNote: String?

    private static let fallbackModels = [
        "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini"
    ]

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
    @AppStorage(AppSettings.keepScreenAwakeKey) private var keepScreenAwake = true
    @AppStorage(AppSettings.claimAirPodsAtStartKey) private var claimAirPodsAtStart = true
    @AppStorage(AppSettings.replyLanguageKey) private var replyLanguage = "zh"
    @AppStorage(AppSettings.prompterEnabledKey) private var prompterEnabled = true
    @AppStorage(AppSettings.autoSuggestKey) private var autoSuggest = true
    @AppStorage(AppSettings.userBioKey) private var userBio = ""
    @AppStorage(AppSettings.mandarinLevelKey) private var mandarinLevelRaw = AppSettings.MandarinLevel.elementary.rawValue
    @AppStorage(AppSettings.suggestionToneKey) private var suggestionTone = "auto"
    @AppStorage(AppSettings.suggestionLimitKey) private var suggestionLimit = 10
    @AppStorage(AppSettings.assistRateLimitKey) private var assistRateLimit = 3.0
    @AppStorage(AppSettings.priorityProcessingKey) private var priorityProcessing = false
    @AppStorage(AppSettings.assistModelKey) private var assistModel = ""
    @AppStorage(AppSettings.assistEndpointKey) private var assistEndpoint = ""

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
                    Toggle("Pull AirPods over at Start", isOn: $claimAirPodsAtStart)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Volume of translated audio, on top of the iPad's hardware volume. Above 100% is a digital boost for loud rooms — the very top of the range can distort. Takes effect immediately. \"Pull AirPods over at Start\" plays a short chime under a media-playback session when a conversation starts — the same signal YouTube sends when it starts playing — so AirPods currently on your iPhone switch to this device by themselves. Hear the chime in your ears and it worked; hear it from the iPad speaker and they didn't move (check Bluetooth → AirPods → Connect to This iPad → Automatically). Only runs when the iPad speaker would otherwise be the output — wired or already-connected headphones skip it. Turn off if you never use AirPods; the grab-and-wait adds a few seconds to Start.")
                }

                Section {
                    Picker("Speakers translate to", selection: $outputLanguage) {
                        ForEach(Self.outputLanguages) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("What anyone says is auto-detected (70+ languages) — this chooses the translated output for the table mics. Changes apply when a lane's next session opens (after an idle close, or on the next Start).")
                }

                Section {
                    Toggle("Enable prompter", isOn: $prompterEnabled)
                    Toggle("Auto-suggest during conversation", isOn: $autoSuggest)
                        .disabled(!prompterEnabled)
                    Picker("Reply language", selection: $replyLanguage) {
                        ForEach(Self.outputLanguages) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    Picker("My Mandarin level", selection: $mandarinLevelRaw) {
                        ForEach(AppSettings.MandarinLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    Picker("Suggestion tone", selection: $suggestionTone) {
                        Text("Match the room").tag("auto")
                        Text("Casual").tag("casual")
                        Text("Polite").tag("polite")
                    }
                    Picker("Suggestions in tray", selection: $suggestionLimit) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("8").tag(8)
                        Text("10").tag(10)
                        Text("15").tag(15)
                        Text("20").tag(20)
                    }
                    Picker("Refresh rate limit", selection: $assistRateLimit) {
                        Text("Off (as fast as possible)").tag(0.0)
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("8 seconds").tag(8.0)
                    }
                    Toggle("Priority processing (≈2× token price)", isOn: $priorityProcessing)
                    TextField(
                        "About you — who you are, how you know the group, safe topics…",
                        text: $userBio,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    Picker("Model", selection: $assistModel) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    if let modelsNote {
                        Text(modelsNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Reply prompter")
                } footer: {
                    Text("The prompter watches the conversation and keeps things you could say ready as cue cards — Chinese plus pinyin you read aloud yourself; nothing is ever played by the iPad. Your level hard-caps suggestion length and vocabulary so every card is actually sayable. \"Suggestions in tray\" caps how many unpinned chips are kept (each refresh asks for more when the limit is higher); pinned chips never count against it. \"Refresh rate limit\" is the minimum gap between suggestion requests — lower is fresher but costs more; Off fires a new request the moment the previous one returns. \"Priority processing\" routes requests to OpenAI's paid fast lane for quicker, more consistent responses (turn it off if requests start erroring — availability depends on your account). The bio and the transcript are sent to OpenAI with your existing key — include nothing you wouldn't say at the table. Set the per-meal scene from the chip on the Conversation tab.")
                }

                Section {
                    Toggle("Keep screen awake", isOn: $keepScreenAwake)
                        .onChange(of: keepScreenAwake) { _, newValue in
                            UIApplication.shared.isIdleTimerDisabled = newValue
                        }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Prevents the iPad from auto-locking while the app is open, so a running conversation is never cut off by the screen going to sleep. Turn off to let the normal auto-lock timer apply (saves battery when you're not translating).")
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
                    TextField("Prompter endpoint", text: $assistEndpoint, prompt: Text(AppSettings.defaultAssistEndpoint))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Only change these if OpenAI renames the model or moves an endpoint, or you route through a relay/proxy — the endpoint template covers the realtime translation sessions, the prompter endpoint covers the suggestion/compose calls (both must point at your relay for everything to work through it). %@ in the template is replaced by the model name. Applies on the next Start / next prompter request.")
                }

                Section {
                    Button("Clear transcript", role: .destructive) {
                        model.transcript.clear()
                    }
                }
            }
            .navigationTitle("Settings")
            // The form is mostly text fields with no submit action — the
            // bio field's Return even inserts a newline — so scrolling and
            // a keyboard-bar Done are the ways out from under the keyboard.
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                }
            }
            .task { await loadAssistModels() }
            .onAppear {
                // The picker needs a concrete selection; materialize the
                // default so the stored value and the UI always agree.
                if assistModel.isEmpty { assistModel = AppSettings.defaultAssistModel }
            }
        }
    }

    /// Fetched list first, static fallback otherwise; the current selection
    /// is always present so the picker never shows an unselectable state.
    private var modelChoices: [String] {
        var choices = availableModels.isEmpty ? Self.fallbackModels : availableModels
        let current = assistModel.isEmpty ? AppSettings.defaultAssistModel : assistModel
        if !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    private func loadAssistModels() async {
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
            Log.warn("[assist] model list fetch failed: \(error.localizedDescription)")
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
