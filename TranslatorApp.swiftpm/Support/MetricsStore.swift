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
/// gate-voiced chunk handed to the client while the server was quiet, until
/// the first content event back on any stream. This is the realtime
/// equivalent of time-to-first-token as the listener experiences it — for
/// lazily-opened sessions it deliberately includes the connect and pre-open
/// queue flush.
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
    /// Hidden thinking tokens (subset of completionTokens) — how much the
    /// model reasoned before writing. The closest observable proxy for
    /// reasoning time without a streaming client; 0 for non-reasoning
    /// models.
    let reasoningTokens: Int
    let model: String
    /// nil when the model has no AssistPricing entry (or the request failed
    /// before usage was reported).
    let estimatedCost: Double?
    let failed: Bool
}

/// Everything the Metrics tab draws, as one immutable value.
struct MetricsSnapshot {
    var sessionStartedAt: Date?
    /// true from conversation start until stop.
    var isLive: Bool
    /// Lane ID → display name, refreshed each sample so MetricsView never
    /// needs to observe AppModel.
    var laneNames: [Int: String]
    var samples: [PipelineSample]
    var connects: [ConnectSample]
    var firstResponses: [FirstResponseSample]
    var assistRequests: [AssistRequestSample]
    /// From the store's running ledger — deliberately NOT derived from the
    /// capped assistRequests array, which is a display window that drops old
    /// entries; deriving from it would make the overview tile disagree with
    /// the cost chart in long conversations.
    var assistCostTotal: Double

    var realtimeCostTotal: Double { samples.last?.realtimeCost ?? 0 }
    var isEmpty: Bool {
        samples.isEmpty && connects.isEmpty && firstResponses.isEmpty && assistRequests.isEmpty
    }

    static let empty = MetricsSnapshot(
        sessionStartedAt: nil,
        isLive: false,
        laneNames: [:],
        samples: [],
        connects: [],
        firstResponses: [],
        assistRequests: [],
        assistCostTotal: 0
    )
}

// MARK: - Prompter pricing

/// Published OpenAI chat-completions prices, $ per 1M tokens, for the models
/// the Settings picker is likely to select. Longest matching prefix wins, so
/// entry order never matters. Models with no entry chart tokens only and are
/// excluded from the cost estimate. Like CostMeter's realtime rate, this is
/// a hardcoded snapshot — update it when prices move.
enum AssistPricing {
    private static let perMillionTokens: [String: (input: Double, output: Double)] = [
        "gpt-5": (1.25, 10.00),          // also matches gpt-5.x / gpt-5-chat-*
        "gpt-5-mini": (0.25, 2.00),
        "gpt-5-nano": (0.05, 0.40),
        "gpt-4.1": (2.00, 8.00),
        "gpt-4.1-mini": (0.40, 1.60),
        "gpt-4.1-nano": (0.10, 0.40),
        "gpt-4o": (2.50, 10.00),
        "gpt-4o-mini": (0.15, 0.60),
        "o4-mini": (1.10, 4.40),
        "o3": (2.00, 8.00),
        "o3-mini": (1.10, 4.40),
        "o1": (15.00, 60.00),
    ]

    static func estimatedDollars(model: String, promptTokens: Int, completionTokens: Int) -> Double? {
        let match = perMillionTokens
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }
        guard let (_, price) = match else { return nil }
        return Double(promptTokens) / 1_000_000 * price.input
            + Double(completionTokens) / 1_000_000 * price.output
    }
}

// MARK: - Store

/// Collects one conversation's metrics for the Metrics tab: cost over time,
/// connect and first-response latency, audio/text throughput, and prompter
/// token usage. History is cleared when the next conversation successfully
/// starts, so a finished session stays inspectable.
///
/// Threading: everything is main-thread confined — the 1 Hz sample comes
/// from AppModel's UI timer, and AppModel hops client callbacks to main
/// before recording. The published snapshot is only rebuilt while the tab
/// is visible (and at most once per main-queue turn); recording continues
/// regardless, so opening the tab shows the full history.
final class MetricsStore: ObservableObject {

    @Published private(set) var snapshot = MetricsSnapshot.empty

    /// 1 Hz samples: one hour of history.
    static let sampleCapacity = 3600
    static let eventCapacity = 400

    private var samples = RingBuffer<PipelineSample>(capacity: MetricsStore.sampleCapacity)
    private var connects = RingBuffer<ConnectSample>(capacity: MetricsStore.eventCapacity)
    private var firstResponses = RingBuffer<FirstResponseSample>(capacity: MetricsStore.eventCapacity)
    private var assistRequests = RingBuffer<AssistRequestSample>(capacity: MetricsStore.eventCapacity)
    private var sessionStartedAt: Date?
    private var isLive = false
    private var laneNames: [Int: String] = [:]
    /// The prompter-cost ledger; never trimmed (unlike the request events).
    private var assistCostTotal: Double = 0

    /// Per-lane last-seen client counters, for rate-of-change between
    /// samples. Counters restart at zero on every reconnect; the snapshot's
    /// connectionID says which connection a reading belongs to, so a change
    /// of identity (not a value dip, which a pre-open queue flush can mask
    /// within one tick) resets the baseline.
    private struct LaneTotals {
        var connectionID: UUID?
        var audioSent: Double = 0
        var audioReceived: Double = 0
        var sourceChars: Int = 0
        var translationChars: Int = 0
    }
    private var laneTotals: [Int: LaneTotals] = [:]
    private var lastSampleAt: Date?

    private var visible = false
    private var dirty = false
    private var publishScheduled = false

    // MARK: - Lifecycle

    /// Toggle from MetricsView.onAppear/.onDisappear: the snapshot rebuild
    /// (an O(history) copy) only runs while someone is looking at it.
    func setVisible(_ on: Bool) {
        visible = on
        if on, dirty { publish() }
    }

    /// Called from AppModel.startConversation once every fallible setup step
    /// has succeeded — the tab reads as "this conversation's metrics",
    /// mirroring CostMeter.reset().
    func startSession() {
        samples = RingBuffer(capacity: Self.sampleCapacity)
        connects = RingBuffer(capacity: Self.eventCapacity)
        firstResponses = RingBuffer(capacity: Self.eventCapacity)
        assistRequests = RingBuffer(capacity: Self.eventCapacity)
        assistCostTotal = 0
        laneTotals = [:]
        laneNames = [:]
        lastSampleAt = nil
        sessionStartedAt = Date()
        isLive = true
        schedulePublish()
    }

    /// The conversation stopped; history stays for review.
    func endSession() {
        isLive = false
        schedulePublish()
    }

    // MARK: - Recording (main thread)

    /// One 1 Hz tick: cumulative cost from the meter plus each live lane's
    /// client counters (the same snapshots the Diagnostics pipeline rows
    /// use). Rates are the counter deltas since the previous tick.
    func sample(realtimeCost: Double, lanes: [Int: RealtimeTranslationClient.Snapshot], laneNames: [Int: String]) {
        let now = Date()
        let dt = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        lastSampleAt = now
        self.laneNames = laneNames

        var audioIn = 0.0, audioOut = 0.0
        var sourceChars = 0.0, translationChars = 0.0
        var open = 0
        for (lane, session) in lanes {
            if session.state == .open { open += 1 }
            // A different connectionID means the counters restarted at zero:
            // diff against a zero baseline so the whole reading counts.
            // (Traffic the old connection sent between the last tick and its
            // death is lost from the rate charts; cost comes from CostMeter,
            // which never resets mid-conversation.)
            let previous = laneTotals[lane]
            let base = previous?.connectionID == session.connectionID
                ? previous!
                : LaneTotals(connectionID: session.connectionID)
            audioIn += max(0, session.audioSecondsSent - base.audioSent)
            audioOut += max(0, session.audioSecondsReceived - base.audioReceived)
            sourceChars += Double(max(0, session.sourceChars - base.sourceChars))
            translationChars += Double(max(0, session.translationChars - base.translationChars))
            laneTotals[lane] = LaneTotals(
                connectionID: session.connectionID,
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
        schedulePublish()
    }

    func recordConnect(lane: Int, seconds: Double) {
        connects.append(ConnectSample(date: Date(), lane: lane, seconds: seconds))
        schedulePublish()
    }

    func recordFirstResponse(lane: Int, seconds: Double) {
        firstResponses.append(FirstResponseSample(date: Date(), lane: lane, seconds: seconds))
        schedulePublish()
    }

    func recordAssist(_ sample: AssistRequestSample) {
        assistRequests.append(sample)
        if let cost = sample.estimatedCost { assistCostTotal += cost }
        schedulePublish()
    }

    // MARK: - Publishing

    /// Coalesce bursts (e.g. four lanes reconnecting in the same tick) into
    /// one snapshot rebuild per main-queue turn.
    private func schedulePublish() {
        guard visible else {
            dirty = true
            return
        }
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            if self.visible {
                self.publish()
            } else {
                self.dirty = true
            }
        }
    }

    private func publish() {
        dirty = false
        snapshot = MetricsSnapshot(
            sessionStartedAt: sessionStartedAt,
            isLive: isLive,
            laneNames: laneNames,
            samples: samples.ordered(),
            connects: connects.ordered(),
            firstResponses: firstResponses.ordered(),
            assistRequests: assistRequests.ordered(),
            assistCostTotal: assistCostTotal
        )
    }
}
