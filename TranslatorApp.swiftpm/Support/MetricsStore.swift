import Foundation
import Combine

// MARK: - Sample types

/// One 1 Hz sample of the pipeline-wide counters, taken by AppModel's UI
/// timer while a conversation runs.
struct PipelineSample: Identifiable {
    var id: Date { date }
    let date: Date
    /// Cumulative realtime-session dollars this conversation (CostMeter).
    let realtimeCost: Double
    /// Cumulative estimated prompter dollars this conversation. Requests
    /// whose model has no AssistPricing entry contribute nothing here (their
    /// tokens still chart).
    let assistCost: Double
    /// Seconds of audio appended to translation sessions per wall-clock
    /// second, all lanes summed — 1.0 means one lane streaming continuously,
    /// 4.0 means all four are.
    let audioInRate: Double
    /// Seconds of translated audio received per wall-clock second, all lanes.
    let audioOutRate: Double
    /// Source-language transcript characters received per second.
    let sourceCharsPerSecond: Double
    /// Translated transcript characters received per second.
    let translationCharsPerSecond: Double
    /// Translation sessions currently in the .open state.
    let openSessions: Int
}

/// WebSocket connect duration for one session (connect() → 101 upgrade).
struct ConnectSample: Identifiable {
    let id = UUID()
    let date: Date
    let lane: Int
    let seconds: Double
}

/// Speech-to-first-response latency for one utterance burst: from the first
/// speech chunk handed to the client while the server was quiet, until the
/// first content event back on any stream. This is the realtime equivalent
/// of time-to-first-token as the listener experiences it — for lazily-opened
/// sessions it deliberately includes the connect and pre-open queue flush.
struct FirstResponseSample: Identifiable {
    let id = UUID()
    let date: Date
    let lane: Int
    let seconds: Double
}

/// One prompter (chat-completions) round trip.
struct AssistRequestSample: Identifiable {
    let id = UUID()
    let date: Date
    /// ambient | reply | compose | explain
    let kind: String
    let seconds: Double
    /// Prompt tokens are the request's entire context (system prompt +
    /// transcript window + tray) — the direct context-size measure for the
    /// prompter.
    let promptTokens: Int
    let completionTokens: Int
    let model: String
    /// nil when the model has no AssistPricing entry (or the request failed
    /// before usage was reported).
    let estimatedCost: Double?
    let failed: Bool
}

/// Everything the Metrics tab draws, as one immutable value.
struct MetricsSnapshot {
    var sessionStartedAt: Date?
    var samples: [PipelineSample]
    var connects: [ConnectSample]
    var firstResponses: [FirstResponseSample]
    var assistRequests: [AssistRequestSample]

    var realtimeCostTotal: Double { samples.last?.realtimeCost ?? 0 }
    var assistCostTotal: Double { assistRequests.compactMap(\.estimatedCost).reduce(0, +) }
    var isEmpty: Bool {
        samples.isEmpty && connects.isEmpty && firstResponses.isEmpty && assistRequests.isEmpty
    }

    static let empty = MetricsSnapshot(
        sessionStartedAt: nil,
        samples: [],
        connects: [],
        firstResponses: [],
        assistRequests: []
    )
}

// MARK: - Prompter pricing

/// Published OpenAI chat-completions prices, $ per 1M tokens, for the models
/// the Settings picker is likely to select. Longest-prefix match; models
/// with no entry chart tokens only and are excluded from the cost estimate.
/// Like CostMeter's realtime rate, this is a hardcoded snapshot — update it
/// when prices move.
enum AssistPricing {
    private static let perMillionTokens: [(prefix: String, input: Double, output: Double)] = [
        ("gpt-5-nano", 0.05, 0.40),
        ("gpt-5-mini", 0.25, 2.00),
        ("gpt-5", 1.25, 10.00),          // gpt-5, gpt-5.x, gpt-5-chat-*
        ("gpt-4.1-nano", 0.10, 0.40),
        ("gpt-4.1-mini", 0.40, 1.60),
        ("gpt-4.1", 2.00, 8.00),
        ("gpt-4o-mini", 0.15, 0.60),
        ("gpt-4o", 2.50, 10.00),
        ("o4-mini", 1.10, 4.40),
        ("o3-mini", 1.10, 4.40),
        ("o3", 2.00, 8.00),
        ("o1", 15.00, 60.00),
    ]

    static func estimatedDollars(model: String, promptTokens: Int, completionTokens: Int) -> Double? {
        guard let entry = perMillionTokens.first(where: { model.hasPrefix($0.prefix) }) else { return nil }
        return Double(promptTokens) / 1_000_000 * entry.input
            + Double(completionTokens) / 1_000_000 * entry.output
    }
}

// MARK: - Store

/// Collects one conversation's metrics for the Metrics tab: cost over time,
/// connect and first-response latency, audio/text throughput, and prompter
/// token usage. History is cleared when the next conversation starts, so a
/// finished session stays inspectable.
///
/// Threading: everything is main-thread confined — the 1 Hz sample comes
/// from AppModel's UI timer, and AppModel hops client callbacks to main
/// before recording. The published snapshot is only rebuilt while the tab
/// is visible; recording continues regardless, so opening the tab shows the
/// full history.
final class MetricsStore: ObservableObject {

    @Published private(set) var snapshot = MetricsSnapshot.empty

    /// 1 Hz samples: one hour of history.
    static let sampleCapacity = 3600
    static let eventCapacity = 400

    private var samples = RingBuffer<PipelineSample>(capacity: MetricsStore.sampleCapacity)
    private var connects: [ConnectSample] = []
    private var firstResponses: [FirstResponseSample] = []
    private var assistRequests: [AssistRequestSample] = []
    private var sessionStartedAt: Date?
    private var assistCostTotal: Double = 0

    /// Per-lane last-seen client counters, for rate-of-change between
    /// samples. Client counters reset on every reconnect, so deltas are
    /// computed with reset detection rather than plain subtraction.
    private struct LaneTotals {
        var audioSent: Double = 0
        var audioReceived: Double = 0
        var sourceChars: Int = 0
        var translationChars: Int = 0
    }
    private var laneTotals: [Int: LaneTotals] = [:]
    private var lastSampleAt: Date?

    private var visible = false
    private var dirty = false

    // MARK: - Lifecycle

    /// Toggle from MetricsView.onAppear/.onDisappear: the snapshot rebuild
    /// (an O(history) copy) only runs while someone is looking at it.
    func setVisible(_ on: Bool) {
        visible = on
        if on, dirty { publish() }
    }

    /// Called from AppModel.startConversation — the tab reads as "this
    /// conversation's metrics", mirroring CostMeter.reset().
    func startSession() {
        samples = RingBuffer(capacity: Self.sampleCapacity)
        connects = []
        firstResponses = []
        assistRequests = []
        assistCostTotal = 0
        laneTotals = [:]
        lastSampleAt = nil
        sessionStartedAt = Date()
        publish()
    }

    // MARK: - Recording (main thread)

    /// One 1 Hz tick: cumulative cost from the meter plus each live lane's
    /// client counters (the same snapshots the Diagnostics pipeline rows
    /// use). Rates are the counter deltas since the previous tick.
    func sample(realtimeCost: Double, lanes: [Int: RealtimeTranslationClient.Snapshot]) {
        let now = Date()
        let dt = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        lastSampleAt = now

        var audioIn = 0.0, audioOut = 0.0
        var sourceChars = 0.0, translationChars = 0.0
        var open = 0
        for (lane, session) in lanes {
            if session.state == .open { open += 1 }
            let previous = laneTotals[lane] ?? LaneTotals()
            audioIn += delta(session.audioSecondsSent, previous.audioSent)
            audioOut += delta(session.audioSecondsReceived, previous.audioReceived)
            sourceChars += delta(Double(session.sourceChars), Double(previous.sourceChars))
            translationChars += delta(Double(session.translationChars), Double(previous.translationChars))
            laneTotals[lane] = LaneTotals(
                audioSent: session.audioSecondsSent,
                audioReceived: session.audioSecondsReceived,
                sourceChars: session.sourceChars,
                translationChars: session.translationChars
            )
        }

        // No rate basis on the first tick (or after a timer stall).
        let rateDT = (dt > 0.2 && dt < 10) ? dt : 0
        samples.append(PipelineSample(
            date: now,
            realtimeCost: realtimeCost,
            assistCost: assistCostTotal,
            audioInRate: rateDT > 0 ? audioIn / rateDT : 0,
            audioOutRate: rateDT > 0 ? audioOut / rateDT : 0,
            sourceCharsPerSecond: rateDT > 0 ? sourceChars / rateDT : 0,
            translationCharsPerSecond: rateDT > 0 ? translationChars / rateDT : 0,
            openSessions: open
        ))
        publish()
    }

    func recordConnect(lane: Int, seconds: Double) {
        connects.append(ConnectSample(date: Date(), lane: lane, seconds: seconds))
        trim(&connects)
        publish()
    }

    func recordFirstResponse(lane: Int, seconds: Double) {
        firstResponses.append(FirstResponseSample(date: Date(), lane: lane, seconds: seconds))
        trim(&firstResponses)
        publish()
    }

    func recordAssist(_ sample: AssistRequestSample) {
        assistRequests.append(sample)
        trim(&assistRequests)
        if let cost = sample.estimatedCost { assistCostTotal += cost }
        publish()
    }

    // MARK: - Internals

    /// Counter delta with reset detection: a value below the previous sample
    /// means the connection restarted and its counters began again at zero,
    /// so the whole new reading is fresh progress. (Audio billed between the
    /// last tick and the reset is lost from the *rate* charts only — cost
    /// comes from CostMeter, which never resets mid-conversation.)
    private func delta(_ new: Double, _ old: Double) -> Double {
        new >= old ? new - old : new
    }

    private func trim<T>(_ events: inout [T]) {
        if events.count > Self.eventCapacity {
            events.removeFirst(events.count - Self.eventCapacity)
        }
    }

    private func publish() {
        guard visible else {
            dirty = true
            return
        }
        dirty = false
        snapshot = MetricsSnapshot(
            sessionStartedAt: sessionStartedAt,
            samples: samples.ordered(),
            connects: connects,
            firstResponses: firstResponses,
            assistRequests: assistRequests
        )
    }
}
