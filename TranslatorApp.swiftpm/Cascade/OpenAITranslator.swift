import Foundation
import Translation

/// Errors the OpenAI translation stage surfaces to the lane engine.
/// Deliberately NEVER TranslationError.notInstalled: the engine treats
/// that as stage-fatal (translationDead) for the Apple-PRIMARY path, and
/// a missing FALLBACK pack must not kill a cloud stage that may recover.
enum TranslationStageError: LocalizedError {
    /// Cloud request failed and the on-device fallback also failed.
    case cloudFailed(String)
    /// Cloud request failed and the fallback pack is not installed —
    /// drives the Diagnostics "fallback unavailable" symptom.
    case fallbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .cloudFailed(let detail):
            return "OpenAI translation failed (\(detail))"
        case .fallbackUnavailable(let detail):
            return "OpenAI translation failed (\(detail)) — offline fallback pack not installed"
        }
    }
}

/// GLOBAL health for the OpenAI translation stage, shared by all lanes
/// (docs/CASCADE-PIPELINE.md §14.1): network death is global, and
/// per-lane failure counters would serialize up to 4 × 3 × 8 s of
/// stalls. Three consecutive failures latch every lane onto the Apple
/// fallback; recovery is half-open — a synthetic probe request every
/// ~60 s (never a real utterance, so real translations never stall on
/// retries) un-latches on success.
///
/// Threading: counters behind a lock; callables invoked OUTSIDE the lock.
/// onNotice/onCostDelta are wired once by AppModel at Start, before any
/// job can fail.
final class OpenAITranslationHealth {

    static let latchThreshold = 3
    static let probeIntervalSeconds: TimeInterval = 60
    private static let noticeID = "cascade.mt.latch"

    /// AppModel hops to main and feeds handleNotice (id-keyed banner).
    var onNotice: ((LaneNotice) -> Void)?
    /// The probe's token cost — Diagnostics honesty: even fractions of a
    /// cent flow through the same meter as real jobs.
    var onCostDelta: ((Double) -> Void)?

    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var latched = false
    private var tornDown = false
    private var probeTask: Task<Void, Never>?
    /// Tiny synthetic request; returns its estimated cost (nil when the
    /// model is unpriced). Injected by CascadeContext.
    private let probe: () async throws -> Double?

    init(probe: @escaping () async throws -> Double?) {
        self.probe = probe
    }

    var isLatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latched
    }

    /// A real job (or the probe) got a cloud response.
    func recordSuccess() {
        lock.lock()
        // Symmetric with recordFailure: a success resolving after Stop
        // must not mutate latch state or fire notices into the stopped
        // app (review NIT).
        guard !tornDown else {
            lock.unlock()
            return
        }
        consecutiveFailures = 0
        let wasLatched = latched
        latched = false
        let task = probeTask
        probeTask = nil
        lock.unlock()
        task?.cancel()
        if wasLatched {
            Log.info("[cascade mt] OpenAI translation recovered — un-latching the fallback")
            onNotice?(.cleared(id: Self.noticeID))
        }
    }

    /// A real job's cloud request failed. Latch on the threshold.
    func recordFailure() {
        lock.lock()
        guard !tornDown else {
            lock.unlock()
            return
        }
        consecutiveFailures += 1
        let shouldLatch = !latched && consecutiveFailures >= Self.latchThreshold
        if shouldLatch {
            latched = true
            startProbeLoopLocked()
        }
        lock.unlock()
        if shouldLatch {
            Log.warn("[cascade mt] \(Self.latchThreshold) consecutive OpenAI failures — latching all lanes onto the Apple fallback (half-open probe every \(Int(Self.probeIntervalSeconds))s)")
            onNotice?(.raised(
                id: Self.noticeID,
                text: "OpenAI translation unreachable — using Apple translation until it recovers."
            ))
        }
    }

    /// Must be called with the lock held.
    private func startProbeLoopLocked() {
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.probeIntervalSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled, self.isLatched else { return }
                do {
                    let cost = try await self.probe()
                    if let cost { self.onCostDelta?(cost) }
                    // recordSuccess un-latches, clears the banner, and
                    // cancels this task (a cancelled Task keeps running
                    // to its next suspension — the loop guard exits it).
                    self.recordSuccess()
                    return
                } catch {
                    Log.info("[cascade mt] recovery probe failed (\(error.localizedDescription)) — still latched")
                }
            }
        }
    }

    /// Stop-time: end the probe loop and freeze the latch state.
    func teardown() {
        lock.lock()
        tornDown = true
        let task = probeTask
        probeTask = nil
        lock.unlock()
        task?.cancel()
    }
}

/// A `Translator` over streaming chat completions, one instance PER LANE
/// (docs/CASCADE-PIPELINE.md §14.1): each lane's jobs stay FIFO via the
/// engine's one-in-flight pump, while lanes translate in parallel — at
/// 0.5–1.5 s/request, a shared serial queue would back up behind four
/// chatty lanes in a way Apple's 62 ms never did.
///
/// Context is the point: the request carries the scene line, the pushed
/// cross-lane window of recent exchanges with speaker names, and the
/// source utterance — table context disambiguates the pronouns/ellipsis
/// where literal MT fails.
final class OpenAIChatTranslator: Translator {

    /// Overall per-job deadline: cloud attempt including streaming. On
    /// breach the job falls back — a conversation cannot wait longer for
    /// a better translation than a listener waits for ANY translation.
    static let jobTimeoutSeconds: TimeInterval = 8

    var onDelta: ((UUID, String) -> Void)?
    var onCostDelta: ((Double) -> Void)?

    private let label: String
    private let request: OpenAITranslationRequest
    private let health: OpenAITranslationHealth
    /// The lazily-created SHARED Apple fallback (CascadeContext owns it;
    /// per-pair cardinality — §5.2). nil once the context is torn down.
    private let fallback: () -> AppleTranslator?
    /// Fail-fast flag for post-Stop submissions; in-flight requests
    /// resolve into a closed engine, which drops them.
    private let cancelledFlag = LockedFlag()

    init(lane: Int,
         request: OpenAITranslationRequest,
         health: OpenAITranslationHealth,
         fallback: @escaping () -> AppleTranslator?) {
        self.label = "openai mt ch\(lane)"
        self.request = request
        self.health = health
        self.fallback = fallback
    }

    func translate(_ text: String, context: [TranslationContextPair], job: UUID) async throws -> TranslationResult {
        guard !cancelledFlag.isSet else { throw CancellationError() }
        // Latched: go straight to the fallback — no per-job 8 s stall
        // while the network is known-dead. The half-open probe owns
        // recovery.
        if health.isLatched {
            return try await fallbackTranslate(text, job: job, cloudDetail: "latched")
        }
        // Deltas must stop the moment the job resolves (single-resolution
        // invariant): a late-streaming chunk after a timeout-triggered
        // fallback must not repaint the bubble the fallback already owns.
        let resolved = LockedFlag()
        let request = self.request
        do {
            let (translated, cost) = try await Self.withTimeout(Self.jobTimeoutSeconds) {
                try await request.stream(text: text, context: context) { [weak self] partial in
                    guard let self, !resolved.isSet, !partial.isEmpty else { return }
                    self.onDelta?(job, partial)
                }
            }
            resolved.set()
            if let cost { onCostDelta?(cost) }
            // An empty completion is a failure, not a translation — count
            // it against the latch and let the fallback speak.
            guard !translated.isEmpty else {
                health.recordFailure()
                Log.warn("[\(label)] empty completion — falling back for this job")
                return try await fallbackTranslate(text, job: job, cloudDetail: "empty completion")
            }
            health.recordSuccess()
            return TranslationResult(text: translated, viaFallback: false)
        } catch {
            resolved.set()
            guard !cancelledFlag.isSet else { throw CancellationError() }
            health.recordFailure()
            let detail = (error is TimeoutError) ? "timed out after \(Int(Self.jobTimeoutSeconds))s" : error.localizedDescription
            Log.warn("[\(label)] cloud translation failed (\(detail)) — falling back for this job")
            return try await fallbackTranslate(text, job: job, cloudDetail: detail)
        }
    }

    /// Per-job Apple fallback (§14.1). Throws TranslationStageError —
    /// never TranslationError.notInstalled, which would trip the engine's
    /// Apple-primary stage-fatal latch and kill a recoverable cloud stage.
    private func fallbackTranslate(_ text: String, job: UUID, cloudDetail: String) async throws -> TranslationResult {
        guard let translator = fallback() else { throw CancellationError() }
        do {
            let result = try await translator.translate(text, context: [], job: job)
            return TranslationResult(text: result.text, viaFallback: true)
        } catch {
            if TranslationError.notInstalled ~= error {
                throw TranslationStageError.fallbackUnavailable(cloudDetail)
            }
            throw TranslationStageError.cloudFailed("\(cloudDetail); fallback: \(error.localizedDescription)")
        }
    }

    func cancelAll() {
        cancelledFlag.set()
    }

    struct TimeoutError: Error {}

    /// Race the operation against a deadline; exactly one outcome wins
    /// and the loser is cancelled (URLSession's async APIs honor task
    /// cancellation promptly, so the group never lingers). Internal so
    /// CascadeContext's recovery probe gets the same OVERALL deadline as
    /// real jobs — timeoutInterval alone is an idle timeout, and a
    /// dribbling response must not stretch a probe iteration (review NIT).
    static func withTimeout<T>(_ seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimeoutError() }
            return first
        }
    }
}

/// Minimal thread-safe latch (set-once, read-many).
final class LockedFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// One streaming chat-completions translation request — the thin sibling
/// of ChatCompletionClient (that client is non-streaming strict-JSON;
/// this stage needs SSE deltas and plain text). Mirrors its
/// reasoning-effort floor, verbosity, priority tier, and endpoint
/// rerouting so relay users work identically.
struct OpenAITranslationRequest {
    let apiKey: String
    let model: String
    /// Human-readable language names — models follow "Simplified Chinese
    /// → English" more reliably than raw BCP-47 tags.
    let sourceName: String
    let targetName: String
    var endpoint: URL = AppSettings.assistEndpoint

    enum RequestError: LocalizedError {
        case badStatus(Int, String)
        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body): return "HTTP \(code): \(body)"
            }
        }
    }

    /// Returns the full translation and its estimated cost (nil when the
    /// model has no AssistPricing entry). `onPartial` receives the
    /// ACCUMULATED text as chunks stream.
    func stream(text: String,
                context: [TranslationContextPair],
                onPartial: @escaping (String) -> Void) async throws -> (text: String, cost: Double?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = OpenAIChatTranslator.jobTimeoutSeconds

        // The STT-provenance rules are deliberately CLOSED (fix homophones,
        // drop fillers, otherwise literal): an open-ended "the transcript
        // may be wrong" invites confident confabulation — the exact
        // failure mode the "never add content" anchor guards against
        // (worst case: English speech through the Mandarin model).
        var system = """
        You are a professional interpreter for a live \(sourceName) conversation. \
        Each user message is a raw speech-to-text transcript of one spoken utterance — it may contain \
        mis-recognized words (usually replaced by similar-sounding ones), wrong or missing punctuation, \
        and disfluencies. Translate the speaker's intended meaning into \(targetName). \
        If a word is clearly a mis-recognition — a similar-sounding word fits the context much better — \
        translate the intended word. Drop fillers and false starts. If you are unsure what was meant, \
        translate what is written; never add content the transcript doesn't support. \
        Produce natural, idiomatic \(targetName) as a human interpreter would speak it, not a \
        word-for-word rendering. \
        Output ONLY the \(targetName) translation — no explanations, no quotes, no notes. \
        Preserve the speaker's register and tone; resolve pronouns and ellipsis from the conversation context.
        """
        let scene = AppSettings.sceneContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scene.isEmpty {
            system += "\n\nScene: \(scene)"
        }
        if !context.isEmpty {
            system += "\n\nRecent conversation, oldest first (context only — do NOT translate or repeat these lines):\n"
                + context.map { "\($0.speaker): \($0.source) → \($0.translation)" }.joined(separator: "\n")
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ],
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        // Same effort floor as ChatCompletionClient: reasoning models
        // default to multi-second thinking, and MT is latency-critical.
        if model.hasPrefix("gpt-5"), !model.contains("chat") {
            payload["reasoning_effort"] = model.hasPrefix("gpt-5.") ? "none" : "minimal"
            payload["verbosity"] = "low"
        } else if model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            payload["reasoning_effort"] = "low"
        }
        if AppSettings.priorityProcessing {
            payload["service_tier"] = "priority"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RequestError.badStatus(-1, "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The error body arrives on the same byte stream — read a
            // bounded prefix for the log/banner.
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 300 { break }
            }
            throw RequestError.badStatus(http.statusCode, String(body.prefix(300)))
        }

        var accumulated = ""
        var promptTokens = 0
        var completionTokens = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let frame = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if frame == "[DONE]" { break }
            guard let data = frame.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let choices = root["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let chunk = delta["content"] as? String, !chunk.isEmpty {
                accumulated += chunk
                onPartial(accumulated.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // include_usage: the final chunk carries usage with empty
            // choices.
            if let usage = root["usage"] as? [String: Any] {
                promptTokens = usage["prompt_tokens"] as? Int ?? 0
                completionTokens = usage["completion_tokens"] as? Int ?? 0
            }
        }
        let cost = AssistPricing.estimatedDollars(
            model: model, promptTokens: promptTokens, completionTokens: completionTokens
        )
        return (accumulated.trimmingCharacters(in: .whitespacesAndNewlines), cost)
    }
}
