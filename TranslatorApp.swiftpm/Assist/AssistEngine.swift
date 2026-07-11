import Foundation
import Combine

/// The reply prompter (docs/REPLY-FLOW.md): watches the transcript and keeps
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
        /// false = still streaming (included so sentence-boundary-triggered
        /// requests can see the sentence that triggered them).
        let isFinal: Bool
    }

    struct Suggestion: Identifiable, Equatable {
        let id: String
        /// Short intent description ("Ask how long the drive was") — what
        /// the chips show.
        var gloss: String
        /// Literal English translation of the exact line — what the cue
        /// card shows so the user knows precisely what they're saying.
        var meaning: String
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
    /// High-water mark over the transcript's monotonic content counters
    /// (finalizations + streamed sentence boundaries).
    private var lastContentEvents = 0
    private var lastRequestAt = Date.distantPast
    private var pendingAmbient = false
    /// Bumped by manual/scoped requests and conversation end — an ambient
    /// response from an older generation is dropped; same-generation late
    /// responses are applied even if newer speech has finalized.
    private var generation = 0
    /// Identifies the newest fired request. A completion only clears the
    /// in-flight slot when it belongs to this request — otherwise a
    /// superseded response would free the slot while its successor is
    /// still airborne and let a third request overlap it.
    private var requestCounter = 0
    private var activeRequestID: Int?
    private var inFlight: Bool { activeRequestID != nil }
    /// Invalidates any scheduled boundary fire; bumped by manual/scoped
    /// requests and conversation end so a queued ambient trigger can't
    /// fire after being superseded (or after settings/conversation change).
    private var boundaryToken = 0
    private var boundaryFireScheduled = false
    /// Chip ids consumed via "I said this" while a request was in flight —
    /// a keep referencing one is a chip the user already said, not a new
    /// suggestion. Cleared once the in-flight response is merged.
    private var consumedChipIDs: Set<String> = []
    private var lastEngagedThread: String?
    private var chipCounter = 0
    /// Read live so the Settings picker applies mid-conversation. 0 means
    /// no pacing at all — one-in-flight is then the only throttle.
    private var minRequestInterval: TimeInterval { AppSettings.assistMinRequestInterval }

    // MARK: - Lifecycle (called by AppModel)

    func conversationStarted(contentEvents: Int) {
        conversationActive = true
        lastContentEvents = contentEvents
        lastEngagedThread = nil
        suggestions = []
        pendingAmbient = false
        boundaryToken += 1
        boundaryFireScheduled = false
        activeRequestID = nil
        consumedChipIDs.removeAll()
        status = .idle
    }

    func conversationEnded() {
        conversationActive = false
        pendingAmbient = false
        boundaryToken += 1
        boundaryFireScheduled = false
        generation += 1
        status = .idle
    }

    /// Called at 1 Hz right after finalizeStale AND immediately on each
    /// streamed sentence boundary. Fires the ambient loop when there is
    /// new content since the last request; the rate limit inside
    /// scheduleAmbient bounds how aggressive this can get.
    func transcriptTick(contentEvents: Int) {
        guard conversationActive, AppSettings.prompterEnabled, AppSettings.autoSuggest else {
            lastContentEvents = contentEvents
            return
        }
        guard contentEvents > lastContentEvents else { return }
        lastContentEvents = contentEvents
        scheduleAmbient()
    }

    // MARK: - Manual requests

    /// The "suggest now" button: bypasses the rate limit and supersedes any
    /// in-flight or scheduled ambient batch.
    func requestNow() {
        guard AppSettings.prompterEnabled else { return }
        supersedeAmbient()
        fireAmbient(generation: generation)
    }

    /// Long-press "reply to this": suggestions scoped to one utterance.
    func requestScoped(speaker: String, source: String, translation: String) {
        guard AppSettings.prompterEnabled else { return }
        guard let apiKey = apiKeyOrOffline() else { return }
        supersedeAmbient()
        let gen = generation
        let requestID = beginRequest()
        lastEngagedThread = speaker
        status = .loading
        let window = transcriptWindow?() ?? []
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let system = AssistPrompt.systemPrompt()
        let batchSize = AppSettings.scopedBatchSize
        let message = AssistPrompt.scopedUserMessage(window: window, speaker: speaker, source: source, translation: translation, batchSize: batchSize)
        Task { [weak self] in
            do {
                let response = try await client.complete(system: system, user: message, schemaName: "suggestions", schema: AssistPrompt.suggestionsSchema(maxItems: batchSize))
                await MainActor.run { self?.applyScoped(response, generation: gen, requestID: requestID) }
            } catch {
                await MainActor.run { self?.requestFailed(error, requestID: requestID) }
            }
        }
    }

    /// A manual request pre-empts the ambient loop: drop any queued demand
    /// and invalidate any scheduled boundary fire — generation bumps alone
    /// only drop *responses*, not pending *triggers* (which would otherwise
    /// fire with the new generation and clobber the manual result).
    private func supersedeAmbient() {
        generation += 1
        pendingAmbient = false
        boundaryToken += 1
        boundaryFireScheduled = false
    }

    /// Composer: one sayable line from the user's draft. Independent of the
    /// ambient loop — it produces a cue card, never touches the tray.
    func compose(draft: String) async -> Suggestion? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, AppSettings.prompterEnabled else { return nil }
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
                self.clearOfflineStatus()
                return Self.parseSuggestions(response.content, nextID: { self.nextChipID() }).first?.suggestion
            }
        } catch {
            await MainActor.run { self.noteFailure(error) }
            return nil
        }
    }

    /// Long-press "explain this": nuance + key phrases, rendered only.
    func explain(speaker: String, source: String, translation: String) async -> Explanation? {
        guard AppSettings.prompterEnabled else { return nil }
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            await MainActor.run { self.status = .offline("Add your OpenAI API key in Settings") }
            return nil
        }
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let system = await MainActor.run { AssistPrompt.systemPrompt() }
        let message = AssistPrompt.explainUserMessage(speaker: speaker, source: source, translation: translation)
        do {
            let response = try await client.complete(system: system, user: message, schemaName: "explanation", schema: AssistPrompt.explanationSchema())
            await MainActor.run {
                self.logUsage(response.usage)
                self.clearOfflineStatus()
            }
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
    /// consume the chip (pinned or not — said means done). The id is also
    /// remembered so an in-flight response that "keeps" this chip can't
    /// resurrect the line the user just said.
    func markSaid(_ suggestion: Suggestion) {
        onUserSaid?(suggestion)
        if let thread = suggestion.replyTo { lastEngagedThread = thread }
        if suggestions.contains(where: { $0.id == suggestion.id }) {
            consumedChipIDs.insert(suggestion.id)
            suggestions.removeAll { $0.id == suggestion.id }
        }
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
            let token = boundaryToken
            DispatchQueue.main.asyncAfter(deadline: .now() + (minRequestInterval - sinceLast)) { [weak self] in
                guard let self, token == self.boundaryToken else { return }
                self.boundaryFireScheduled = false
                // Re-check everything that can change during the wait — a
                // superseded/disabled/stopped trigger must not fire.
                guard self.conversationActive, AppSettings.prompterEnabled, AppSettings.autoSuggest else { return }
                if self.inFlight {
                    self.pendingAmbient = true
                } else {
                    self.fireAmbient(generation: self.generation)
                }
            }
        }
    }

    /// Claim the in-flight slot for a new request. The returned id must be
    /// handed to completeRequest by whichever completion path runs.
    private func beginRequest() -> Int {
        requestCounter += 1
        activeRequestID = requestCounter
        lastRequestAt = Date()
        return requestCounter
    }

    /// Only the NEWEST request may free the slot — a superseded response
    /// arriving late must not mark its successor's flight as finished.
    private func completeRequest(_ requestID: Int) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
    }

    private func fireAmbient(generation gen: Int) {
        guard let apiKey = apiKeyOrOffline() else { return }
        let window = transcriptWindow?() ?? []
        guard !window.isEmpty else { return }
        let requestID = beginRequest()
        status = .loading
        let client = ChatCompletionClient(apiKey: apiKey, model: AppSettings.assistModel)
        let system = AssistPrompt.systemPrompt()
        let batchSize = AppSettings.suggestionBatchSize
        let message = AssistPrompt.ambientUserMessage(window: window, tray: suggestions, engagedThread: lastEngagedThread, batchSize: batchSize)
        Task { [weak self] in
            do {
                let response = try await client.complete(system: system, user: message, schemaName: "suggestions", schema: AssistPrompt.suggestionsSchema(maxItems: batchSize))
                await MainActor.run { self?.applyAmbient(response, generation: gen, requestID: requestID) }
            } catch {
                await MainActor.run { self?.requestFailed(error, requestID: requestID) }
            }
        }
    }

    private func applyAmbient(_ response: ChatCompletionClient.Response, generation gen: Int, requestID: Int) {
        completeRequest(requestID)
        logUsage(response.usage)
        guard gen == generation, conversationActive else {
            drainPending()
            return
        }
        let incoming = Self.parseSuggestions(response.content, nextID: { self.nextChipID() })
        // Carry-over merge (design §"Tray stability under chaos"): pinned
        // chips always survive AND never count against the tray limit;
        // unpinned chips survive when the model returned them with
        // keep=<id>; genuinely new entries follow, truncated to the
        // configured limit. A keep pointing at a chip the user said while
        // this request was in flight is dropped (saying it consumed it); a
        // keep pointing at an id we never had counts as new.
        let pinned = suggestions.filter(\.pinned)
        var rest: [Suggestion] = []
        let keptIDs = Set(incoming.compactMap(\.keep))
        for chip in suggestions where !chip.pinned && keptIDs.contains(chip.id) {
            rest.append(chip)
        }
        for item in incoming {
            if let keep = item.keep {
                if consumedChipIDs.contains(keep) { continue }
                if !suggestions.contains(where: { $0.id == keep }) {
                    rest.append(item.suggestion)
                }
            } else {
                rest.append(item.suggestion)
            }
        }
        consumedChipIDs.removeAll()
        suggestions = pinned + rest.prefix(AppSettings.suggestionLimit)
        status = .idle
        drainPending()
    }

    private func applyScoped(_ response: ChatCompletionClient.Response, generation gen: Int, requestID: Int) {
        completeRequest(requestID)
        logUsage(response.usage)
        guard gen == generation else {
            drainPending()
            return
        }
        let incoming = Self.parseSuggestions(response.content, nextID: { self.nextChipID() })
        suggestions = suggestions.filter(\.pinned) + incoming.prefix(AppSettings.scopedBatchSize).map(\.suggestion)
        consumedChipIDs.removeAll()
        status = .idle
        // Deliberately NOT draining here: queued ambient demand predates the
        // scoped request, and letting it fire would replace these chips with
        // a generic batch seconds after the user explicitly asked for them.
        // New speech re-arms the loop naturally.
        pendingAmbient = false
    }

    private func drainPending() {
        guard pendingAmbient else { return }
        pendingAmbient = false
        scheduleAmbient()
    }

    private func requestFailed(_ error: Error, requestID: Int) {
        completeRequest(requestID)
        noteFailure(error)
        drainPending()
    }

    private func noteFailure(_ error: Error) {
        let detail = String(error.localizedDescription.prefix(120))
        status = .offline(detail)
        Log.warn("[assist] request failed: \(detail)")
    }

    /// Successful compose/explain calls clear a stale offline badge —
    /// without this, one transient failure sticks until the next
    /// ambient/scoped batch happens to succeed.
    private func clearOfflineStatus() {
        if case .offline = status { status = .idle }
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
            // back to the on-device ICU transform the transcript uses —
            // but only for Mandarin: the Han→Latin transform produces
            // garbage on non-Chinese reply languages.
            let modelPinyin = item["pinyin"] as? String ?? ""
            let pinyin: String
            if !modelPinyin.isEmpty {
                pinyin = modelPinyin
            } else if AppSettings.replyLanguage == "zh" {
                pinyin = hanzi.pinyin ?? ""
            } else {
                pinyin = ""
            }
            let replyTo = (item["reply_to"] as? String).flatMap { $0 == "table" || $0.isEmpty ? nil : $0 }
            let meaning = (item["meaning"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? gloss
            let suggestion = Suggestion(
                id: nextID(),
                gloss: gloss,
                meaning: meaning,
                hanzi: hanzi,
                pinyin: pinyin,
                register: item["register"] as? String ?? "casual",
                replyTo: replyTo
            )
            return IncomingSuggestion(keep: item["keep"] as? String, suggestion: suggestion)
        }
    }
}
