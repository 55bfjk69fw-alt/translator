import Foundation
import Combine

/// The reply co-pilot (docs/REPLY-FLOW.md): watches the transcript and keeps
/// 2–3 sayable suggestions ready, turns typed drafts into cue cards, answers
/// scoped "reply to this" and "explain this" requests, and records what the
/// user actually said aloud. It only ever reads the transcript — it is
/// completely independent of the audio pipeline.
///
/// Trigger discipline (§3 of the design): a finalization fires a request
/// immediately unless one was made in the last 5 s (then a single fire is
/// scheduled at the boundary); one request in flight ever; late ambient
/// responses are applied, not discarded — only manual/scoped requests
/// supersede them.
///
/// All entry points and @Published mutations are main-thread; network calls
/// run in Tasks that hop back via MainActor.run.
final class AssistEngine: ObservableObject {

    struct TranscriptLine {
        let speaker: String
        let source: String
        let translation: String
        let isUser: Bool
    }

    struct Suggestion: Identifiable, Equatable {
        let id: String
        var gloss: String
        var hanzi: String
        var pinyin: String
        var register: String
        /// Speaker/thread this responds to; nil = general table contribution.
        var replyTo: String?
        var pinned: Bool = false
    }

    struct KeyPhrase: Identifiable {
        let id = UUID()
        let hanzi: String
        let pinyin: String
        let meaning: String
    }

    struct Explanation: Identifiable {
        let id = UUID()
        let about: String
        let explanation: String
        let phrases: [KeyPhrase]
    }

    enum Status: Equatable {
        case idle
        case loading
        case offline(String)
    }

    // MARK: - Published UI state (main thread)

    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var status: Status = .idle

    // MARK: - Wiring (set once by AppModel)

    /// Recent finalized utterances, oldest first. Called on main.
    var transcriptWindow: (() -> [TranscriptLine])?
    /// Records a confirmed cue card into the transcript. Called on main.
    var onUserSaid: ((Suggestion) -> Void)?

    // MARK: - Loop state (main thread)

    private var conversationActive = false
    private var lastFinalizedCount = 0
    private var lastRequestAt = Date.distantPast
    private var boundaryFireScheduled = false
    private var inFlight = false
    private var pendingAmbient = false
    /// Bumped by manual/scoped requests and conversation end — an ambient
    /// response from an older generation is dropped; same-generation late
    /// responses are applied even if newer speech has finalized.
    private var generation = 0
    private var lastEngagedThread: String?
    private var chipCounter = 0
    private let minRequestInterval: TimeInterval = 5

    // MARK: - Lifecycle (called by AppModel)

    func conversationStarted(finalizedCount: Int) {
        conversationActive = true
        lastFinalizedCount = finalizedCount
        lastEngagedThread = nil
        suggestions = []
        pendingAmbient = false
        status = .idle
    }

    func conversationEnded() {
        conversationActive = false
        pendingAmbient = false
        generation += 1
        status = .idle
    }

    /// Called at 1 Hz right after finalizeStale. Fires the ambient loop
    /// when new utterances have finalized.
    func transcriptTick(finalizedCount: Int) {
        guard conversationActive, AppSettings.copilotEnabled, AppSettings.autoSuggest else {
            lastFinalizedCount = finalizedCount
            return
        }
        guard finalizedCount > lastFinalizedCount else { return }
        lastFinalizedCount = finalizedCount
        scheduleAmbient()
    }

    // MARK: - Manual requests

    /// The "suggest now" button: bypasses the rate limit and supersedes any
    /// in-flight ambient batch.
    func requestNow() {
        guard AppSettings.copilotEnabled else { return }
        generation += 1
        fireAmbient(generation: generation)
    }

    /// Long-press "reply to this": suggestions scoped to one utterance.
    func requestScoped(speaker: String, source: String, translation: String) {
        guard let apiKey = apiKeyOrOffline() else { return }
        generation += 1
        let gen = generation
        lastEngagedThread = speaker
        inFlight = true
        lastRequestAt = Date()
        status = .loading
        let window = transcriptWindow?() ?? []
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let system = AssistPrompt.systemPrompt()
        let message = AssistPrompt.scopedUserMessage(window: window, speaker: speaker, source: source, translation: translation)
        Task { [weak self] in
            do {
                let response = try await client.complete(system: system, user: message, schemaName: "suggestions", schema: AssistPrompt.suggestionsSchema(maxItems: 3))
                await MainActor.run { self?.applyScoped(response, generation: gen) }
            } catch {
                await MainActor.run { self?.requestFailed(error) }
            }
        }
    }

    /// Composer: one sayable line from the user's draft. Independent of the
    /// ambient loop — it produces a cue card, never touches the tray.
    func compose(draft: String) async -> Suggestion? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            await MainActor.run { self.status = .offline("Add your OpenAI API key in Settings") }
            return nil
        }
        let (window, system) = await MainActor.run {
            (self.transcriptWindow?() ?? [], AssistPrompt.systemPrompt())
        }
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let message = AssistPrompt.composeUserMessage(window: window, draft: trimmed)
        do {
            let response = try await client.complete(system: system, user: message, schemaName: "suggestions", schema: AssistPrompt.suggestionsSchema(maxItems: 1))
            return await MainActor.run { () -> Suggestion? in
                self.logUsage(response.usage)
                return Self.parseSuggestions(response.content, nextID: { self.nextChipID() }).first?.suggestion
            }
        } catch {
            await MainActor.run { self.noteFailure(error) }
            return nil
        }
    }

    /// Long-press "explain this": nuance + key phrases, rendered only.
    func explain(speaker: String, source: String, translation: String) async -> Explanation? {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            await MainActor.run { self.status = .offline("Add your OpenAI API key in Settings") }
            return nil
        }
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let system = await MainActor.run { AssistPrompt.systemPrompt() }
        let message = AssistPrompt.explainUserMessage(speaker: speaker, source: source, translation: translation)
        do {
            let response = try await client.complete(system: system, user: message, schemaName: "explanation", schema: AssistPrompt.explanationSchema())
            await MainActor.run { self.logUsage(response.usage) }
            guard let text = response.content["explanation"] as? String else { return nil }
            let phrases = (response.content["key_phrases"] as? [[String: Any]] ?? []).compactMap { raw -> KeyPhrase? in
                guard let hanzi = raw["hanzi"] as? String,
                      let pinyin = raw["pinyin"] as? String,
                      let meaning = raw["meaning"] as? String else { return nil }
                return KeyPhrase(hanzi: hanzi, pinyin: pinyin, meaning: meaning)
            }
            return Explanation(about: source, explanation: text, phrases: phrases)
        } catch {
            await MainActor.run { self.noteFailure(error) }
            return nil
        }
    }

    // MARK: - Tray actions

    /// The user read this card aloud: record it, remember the thread, and
    /// consume the chip (pinned or not — said means done).
    func markSaid(_ suggestion: Suggestion) {
        onUserSaid?(suggestion)
        if let thread = suggestion.replyTo { lastEngagedThread = thread }
        suggestions.removeAll { $0.id == suggestion.id }
        Log.info("[assist] said: \(suggestion.hanzi)")
    }

    /// Pinned chips survive batch replacement and sit leftmost.
    func togglePin(_ id: String) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].pinned.toggle()
        let pinned = suggestions.filter(\.pinned)
        let rest = suggestions.filter { !$0.pinned }
        suggestions = pinned + rest
    }

    // MARK: - Ambient loop internals

    private func scheduleAmbient() {
        if inFlight {
            pendingAmbient = true
            return
        }
        let sinceLast = Date().timeIntervalSince(lastRequestAt)
        if sinceLast >= minRequestInterval {
            fireAmbient(generation: generation)
        } else if !boundaryFireScheduled {
            boundaryFireScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (minRequestInterval - sinceLast)) { [weak self] in
                guard let self else { return }
                self.boundaryFireScheduled = false
                guard self.conversationActive else { return }
                if self.inFlight {
                    self.pendingAmbient = true
                } else {
                    self.fireAmbient(generation: self.generation)
                }
            }
        }
    }

    private func fireAmbient(generation gen: Int) {
        guard let apiKey = apiKeyOrOffline() else { return }
        let window = transcriptWindow?() ?? []
        guard !window.isEmpty else { return }
        inFlight = true
        lastRequestAt = Date()
        status = .loading
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let system = AssistPrompt.systemPrompt()
        let message = AssistPrompt.ambientUserMessage(window: window, tray: suggestions, engagedThread: lastEngagedThread)
        Task { [weak self] in
            do {
                let response = try await client.complete(system: system, user: message, schemaName: "suggestions", schema: AssistPrompt.suggestionsSchema(maxItems: 3))
                await MainActor.run { self?.applyAmbient(response, generation: gen) }
            } catch {
                await MainActor.run { self?.requestFailed(error) }
            }
        }
    }

    private func applyAmbient(_ response: ChatCompletionClient.Response, generation gen: Int) {
        inFlight = false
        logUsage(response.usage)
        guard gen == generation, conversationActive else {
            drainPending()
            return
        }
        let incoming = Self.parseSuggestions(response.content, nextID: { self.nextChipID() })
        // Carry-over merge (design §"Tray stability under chaos"): pinned
        // chips always survive; unpinned chips survive when the model
        // returned them with keep=<id>; genuinely new entries follow. A keep
        // pointing at an id we no longer have counts as new.
        var next: [Suggestion] = suggestions.filter(\.pinned)
        let keptIDs = Set(incoming.compactMap(\.keep))
        for chip in suggestions where !chip.pinned && keptIDs.contains(chip.id) {
            next.append(chip)
        }
        for item in incoming {
            if let keep = item.keep {
                if !suggestions.contains(where: { $0.id == keep }) {
                    next.append(item.suggestion)
                }
            } else {
                next.append(item.suggestion)
            }
        }
        suggestions = Array(next.prefix(5))
        status = .idle
        drainPending()
    }

    private func applyScoped(_ response: ChatCompletionClient.Response, generation gen: Int) {
        inFlight = false
        logUsage(response.usage)
        guard gen == generation else {
            drainPending()
            return
        }
        let incoming = Self.parseSuggestions(response.content, nextID: { self.nextChipID() })
        suggestions = suggestions.filter(\.pinned) + incoming.prefix(3).map(\.suggestion)
        status = .idle
        drainPending()
    }

    private func drainPending() {
        guard pendingAmbient else { return }
        pendingAmbient = false
        scheduleAmbient()
    }

    private func requestFailed(_ error: Error) {
        inFlight = false
        noteFailure(error)
        drainPending()
    }

    private func noteFailure(_ error: Error) {
        let detail = String(error.localizedDescription.prefix(120))
        status = .offline(detail)
        Log.warn("[assist] request failed: \(detail)")
    }

    private func apiKeyOrOffline() -> String? {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            status = .offline("Add your OpenAI API key in Settings")
            return nil
        }
        return apiKey
    }

    private func nextChipID() -> String {
        chipCounter += 1
        return "s\(chipCounter)"
    }

    private func logUsage(_ usage: ChatCompletionClient.Usage?) {
        guard let usage else { return }
        Log.info("[assist] \(AppSettings.assistModel): \(usage.promptTokens) prompt + \(usage.completionTokens) completion tokens")
    }

    // MARK: - Parsing

    private struct IncomingSuggestion {
        let keep: String?
        let suggestion: Suggestion
    }

    private static func parseSuggestions(_ content: [String: Any], nextID: () -> String) -> [IncomingSuggestion] {
        guard let raw = content["suggestions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let gloss = item["gloss"] as? String,
                  let hanzi = item["hanzi"] as? String, !hanzi.isEmpty else { return nil }
            // Prefer the model's pinyin (better heteronym handling); fall
            // back to the on-device ICU transform the transcript uses.
            let modelPinyin = item["pinyin"] as? String ?? ""
            let pinyin = modelPinyin.isEmpty ? (hanzi.pinyin ?? "") : modelPinyin
            let replyTo = (item["reply_to"] as? String).flatMap { $0 == "table" || $0.isEmpty ? nil : $0 }
            let suggestion = Suggestion(
                id: nextID(),
                gloss: gloss,
                hanzi: hanzi,
                pinyin: pinyin,
                register: item["register"] as? String ?? "casual",
                replyTo: replyTo
            )
            return IncomingSuggestion(keep: item["keep"] as? String, suggestion: suggestion)
        }
    }
}
