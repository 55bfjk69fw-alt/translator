import SwiftUI
import Charts

/// Live session metrics: cost over time, speech-to-first-response and
/// connect latency, audio/text throughput, open sessions, and prompter
/// token usage. Draws from MetricsStore's snapshot, which records for the
/// whole conversation whether or not this tab is visible; snapshot
/// publishing (the expensive copy) only runs while it is.
///
/// Color roles: speaker-identity charts reuse the lane palette used
/// everywhere else in the app; paired-series charts use teal (outbound /
/// input side) vs indigo (inbound / output side); red is reserved for
/// failures.
struct MetricsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var metrics: MetricsStore

    private enum TimeWindow: String, CaseIterable, Identifiable {
        case twoMinutes = "2 min"
        case tenMinutes = "10 min"
        case all = "All"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .twoMinutes: return 120
            case .tenMinutes: return 600
            case .all: return nil
            }
        }
    }

    @State private var timeWindow: TimeWindow = .tenMinutes

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if metrics.snapshot.isEmpty {
                        emptyCard
                    } else {
                        overviewCard
                        costCard
                        latencyCard
                        throughputCard
                        sessionsCard
                        prompterCard
                    }
                }
                .padding()
            }
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Window", selection: $timeWindow) {
                        ForEach(TimeWindow.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .onAppear { metrics.setVisible(true) }
            .onDisappear { metrics.setVisible(false) }
        }
    }

    // MARK: - Windowed data

    private var snapshot: MetricsSnapshot { metrics.snapshot }
    private var samples: [PipelineSample] { windowed(snapshot.samples, \.date) }
    private var connects: [ConnectSample] { windowed(snapshot.connects, \.date) }
    private var firstResponses: [FirstResponseSample] { windowed(snapshot.firstResponses, \.date) }
    private var assistRequests: [AssistRequestSample] { windowed(snapshot.assistRequests, \.date) }

    /// The window's "now" is the newest recorded timestamp, so a finished
    /// conversation still shows its tail instead of an empty chart.
    private var latestDataDate: Date? {
        [snapshot.samples.last?.date,
         snapshot.connects.last?.date,
         snapshot.firstResponses.last?.date,
         snapshot.assistRequests.last?.date]
            .compactMap { $0 }
            .max()
    }

    private func windowed<T>(_ items: [T], _ date: KeyPath<T, Date>) -> [T] {
        var result = items
        if let seconds = timeWindow.seconds, let end = latestDataDate {
            let cutoff = end.addingTimeInterval(-seconds)
            result = result.filter { $0[keyPath: date] >= cutoff }
        }
        return decimate(result, maxCount: 700)
    }

    /// Stride-sample long series so an hour of 1 Hz data doesn't hand the
    /// chart thousands of points; the newest point always survives.
    private func decimate<T>(_ items: [T], maxCount: Int) -> [T] {
        guard items.count > maxCount, let last = items.last else { return items }
        let stride = Double(items.count) / Double(maxCount - 1)
        var result = (0..<(maxCount - 1)).map { items[Int(Double($0) * stride)] }
        result.append(last)
        return result
    }

    /// Lane-identity color scale for whatever lanes appear in the data —
    /// the same colors those speakers wear on every other tab.
    private func laneScale(_ lanes: [Int]) -> (domain: [String], range: [Color]) {
        let unique = Set(lanes).sorted()
        return (unique.map { model.laneName($0) }, unique.map { model.lane(for: $0).color })
    }

    // MARK: - Empty state

    private var emptyCard: some View {
        card("Session metrics") {
            Text("Metrics record while a conversation runs: realtime cost, time to first response, connect latency, audio and text throughput, open sessions, and prompter token usage. Start a conversation from the Conversation tab — history stays here for review after it ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overview tiles

    private var overviewCard: some View {
        let realtime = snapshot.realtimeCostTotal
        let assist = snapshot.assistCostTotal
        let billedMinutes = realtime / CostMeter.dollarsPerSessionMinute
        let responseMedian = median(snapshot.firstResponses.suffix(20).map(\.seconds))
        let connectMedian = median(snapshot.connects.suffix(20).map(\.seconds))
        let unpriced = snapshot.assistRequests.contains { !$0.failed && $0.estimatedCost == nil }
        return card("This conversation") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                tile("Total cost", dollars(realtime + assist),
                     detail: unpriced ? "excludes unpriced prompter model" : nil)
                tile("Realtime audio", dollars(realtime),
                     detail: String(format: "%.1f min billed", billedMinutes))
                tile("Prompter", dollars(assist),
                     detail: "\(snapshot.assistRequests.count) request\(snapshot.assistRequests.count == 1 ? "" : "s")")
                tile("First response", responseMedian.map { secondsString($0) } ?? "—",
                     detail: "median of last \(min(20, snapshot.firstResponses.count))")
                tile("Connect", connectMedian.map { secondsString($0) } ?? "—",
                     detail: "median of last \(min(20, snapshot.connects.count))")
                tile("Duration", elapsedString, detail: sessionStateDetail)
            }
        }
    }

    private func tile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var elapsedString: String {
        guard let start = snapshot.sessionStartedAt else { return "—" }
        // The newest recorded timestamp, not Date(): a finished conversation
        // shows its actual length, and a live one updates at the 1 Hz tick.
        let end = latestDataDate ?? start
        let total = Int(max(0, end.timeIntervalSince(start)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? "\(h):" + String(format: "%02ld:%02ld", m, s)
            : "\(m):" + String(format: "%02ld", s)
    }

    private var sessionStateDetail: String {
        if model.mode == .conversation {
            let open = samples.last?.openSessions ?? 0
            return "live · \(open) session\(open == 1 ? "" : "s") open"
        }
        return "ended"
    }

    // MARK: - Cost

    private var costCard: some View {
        card("Cost over time") {
            Text("Cumulative dollars: realtime audio sessions ($\(String(format: "%.3f", CostMeter.dollarsPerSessionMinute))/min) vs prompter chat requests (estimated from token prices).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Dollars", sample.realtimeCost),
                        series: .value("Series", "Realtime audio")
                    )
                    .foregroundStyle(by: .value("Series", "Realtime audio"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Dollars", sample.assistCost),
                        series: .value("Series", "Prompter")
                    )
                    .foregroundStyle(by: .value("Series", "Prompter"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(["Realtime audio": Color.indigo, "Prompter": Color.teal])
                .frame(height: 160)
            }
        }
    }

    // MARK: - Latency

    private var latencyCard: some View {
        card("Latency") {
            Text("First response — speech leaving the app until the first transcript or audio back (includes connect + queue flush for lazily-opened sessions).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            firstResponseChart
            Divider()
            Text("Connect — WebSocket open time per session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            connectChart
        }
    }

    @ViewBuilder
    private var firstResponseChart: some View {
        let scale = laneScale(firstResponses.map(\.lane))
        chartOrPlaceholder(firstResponses, "No responses measured yet — they appear once speech gets translated.") {
            Chart(firstResponses) { sample in
                PointMark(
                    x: .value("Time", sample.date),
                    y: .value("Seconds", sample.seconds)
                )
                .symbolSize(45)
                .foregroundStyle(by: .value("Speaker", model.laneName(sample.lane)))
            }
            .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
            .frame(height: 150)
        }
    }

    @ViewBuilder
    private var connectChart: some View {
        let scale = laneScale(connects.map(\.lane))
        chartOrPlaceholder(connects, "No connections yet — sessions open on each speaker's first speech.") {
            Chart(connects) { sample in
                PointMark(
                    x: .value("Time", sample.date),
                    y: .value("Seconds", sample.seconds)
                )
                .symbol(.diamond)
                .symbolSize(45)
                .foregroundStyle(by: .value("Speaker", model.laneName(sample.lane)))
            }
            .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
            .frame(height: 110)
        }
    }

    // MARK: - Throughput

    private var throughputCard: some View {
        card("Throughput") {
            Text("Audio — seconds of audio per wall-clock second, all lanes summed (1.0 = one lane streaming continuously).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Audio s/s", sample.audioInRate),
                        series: .value("Direction", "Mic → server")
                    )
                    .foregroundStyle(by: .value("Direction", "Mic → server"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Audio s/s", sample.audioOutRate),
                        series: .value("Direction", "Translation ← server")
                    )
                    .foregroundStyle(by: .value("Direction", "Translation ← server"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(["Mic → server": Color.teal, "Translation ← server": Color.indigo])
                .frame(height: 140)
            }
            Divider()
            Text("Text — transcript characters received per second.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Chars/s", sample.sourceCharsPerSecond),
                        series: .value("Stream", "Source text")
                    )
                    .foregroundStyle(by: .value("Stream", "Source text"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Chars/s", sample.translationCharsPerSecond),
                        series: .value("Stream", "Translation text")
                    )
                    .foregroundStyle(by: .value("Stream", "Translation text"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(["Source text": Color.teal, "Translation text": Color.indigo])
                .frame(height: 140)
            }
        }
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        let maxSessions = max(samples.map(\.openSessions).max() ?? 1, 1)
        let idleClose = AppSettings.idleCloseSeconds
        return card("Open sessions") {
            Text(idleClose > 0
                 ? "Sessions open lazily on first speech and close after \(Int(idleClose)) s of silence — dips here are the idle-close saving money on quiet lanes."
                 : "Sessions open lazily on first speech (idle-close is off, so they stay open until the conversation stops).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                Chart(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        y: .value("Sessions", sample.openSessions)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.indigo.opacity(0.12))
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Sessions", sample.openSessions)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...Double(maxSessions) + 0.5)
                .chartYAxis { AxisMarks(values: .stride(by: 1)) }
                .frame(height: 100)
            }
        }
    }

    // MARK: - Prompter

    private var prompterCard: some View {
        card("Prompter") {
            Text("Tokens per request — the prompt segment is the request's whole context (system + transcript window), so its trend is the context size.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(assistRequests, "No prompter requests yet — they fire as the conversation produces utterances (or from the compose bar).") {
                Chart(assistRequests) { request in
                    BarMark(
                        x: .value("Time", request.date),
                        y: .value("Tokens", request.promptTokens),
                        width: .fixed(7)
                    )
                    .foregroundStyle(by: .value("Part", "Context (prompt)"))
                    BarMark(
                        x: .value("Time", request.date),
                        y: .value("Tokens", request.completionTokens),
                        width: .fixed(7)
                    )
                    .foregroundStyle(by: .value("Part", "Completion"))
                }
                .chartForegroundStyleScale(["Context (prompt)": Color.teal, "Completion": Color.indigo])
                .frame(height: 150)
            }
            if !assistRequests.isEmpty {
                Divider()
                Text("Request duration by kind — red marks are failed requests.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Chart(assistRequests) { request in
                    PointMark(
                        x: .value("Time", request.date),
                        y: .value("Seconds", request.seconds)
                    )
                    .symbol(by: .value("Kind", request.kind))
                    .symbolSize(45)
                    .foregroundStyle(request.failed ? Color.red : Color.indigo)
                }
                .frame(height: 130)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func chartOrPlaceholder<T, C: View>(_ data: [T], _ message: String, @ViewBuilder chart: () -> C) -> some View {
        if data.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            chart()
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func dollars(_ value: Double) -> String {
        if value == 0 { return "$0" }
        return value < 1 ? String(format: "$%.3f", value) : String(format: "$%.2f", value)
    }

    private func secondsString(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f s", value) : String(format: "%.2f s", value)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
