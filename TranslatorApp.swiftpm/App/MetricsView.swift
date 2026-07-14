import SwiftUI
import Charts

/// Live session metrics: cost over time, speech-to-first-response and
/// connect latency, audio/text throughput, open sessions, and prompter
/// token usage. Draws from MetricsStore's snapshot, which records for the
/// whole conversation whether or not this tab is visible; snapshot
/// publishing (the expensive copy) only runs while it is.
///
/// Deliberately observes ONLY MetricsStore — never AppModel, whose meters
/// publish at 10 Hz during a conversation and would re-render every chart
/// at meter rate. Everything the charts need (lane names, live state) rides
/// in the snapshot.
///
/// Color roles: speaker-identity charts reuse the lane palette used
/// everywhere else in the app; paired-series charts use teal (input /
/// outbound side) vs indigo (output / inbound side); red is reserved for
/// failures.
struct MetricsView: View {
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

    // Hosted inside MonitorView's NavigationStack (which owns the pane
    // switcher); this view supplies only its title and toolbar items.
    var body: some View {
        ScrollView {
            content
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

    /// Windowing/decimation runs once per body evaluation here, then the
    /// results are handed down — the cards must not each re-filter the
    /// full history.
    private var content: some View {
        let snapshot = metrics.snapshot
        let end = latestDataDate(snapshot)
        let samples = windowed(snapshot.samples, \.date, end: end)
        let connects = windowed(snapshot.connects, \.date, end: end)
        let firstResponses = windowed(snapshot.firstResponses, \.date, end: end)
        let assistRequests = windowed(snapshot.assistRequests, \.date, end: end)
        return VStack(alignment: .leading, spacing: 14) {
            if snapshot.isEmpty {
                emptyCard
            } else {
                overviewCard(snapshot, samples: samples)
                costCard(samples)
                latencyCard(snapshot, firstResponses: firstResponses, connects: connects)
                throughputCard(samples)
                sessionsCard(samples)
                prompterCard(assistRequests)
            }
        }
    }

    // MARK: - Windowed data

    /// The window's "now" is the newest recorded timestamp, so a finished
    /// conversation still shows its tail instead of an empty chart.
    private func latestDataDate(_ snapshot: MetricsSnapshot) -> Date? {
        [snapshot.samples.last?.date,
         snapshot.connects.last?.date,
         snapshot.firstResponses.last?.date,
         snapshot.assistRequests.last?.date]
            .compactMap { $0 }
            .max()
    }

    private func windowed<T>(_ items: [T], _ date: KeyPath<T, Date>, end: Date?) -> [T] {
        var result = items
        if let seconds = timeWindow.seconds, let end {
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

    // MARK: - Lane identity

    private func laneName(_ lane: Int, _ snapshot: MetricsSnapshot) -> String {
        snapshot.laneNames[lane] ?? "Speaker \(lane + 1)"
    }

    private func laneColor(_ lane: Int) -> Color {
        SpeakerLane.laneColors[max(0, lane) % SpeakerLane.laneColors.count]
    }

    /// Lane-identity labels and color scale for whatever lanes appear in the
    /// data — the same colors those speakers wear on every other tab. Two
    /// speakers renamed identically in Settings must not merge into one
    /// series, so name collisions get channel suffixes.
    private func laneScale(_ lanes: [Int], _ snapshot: MetricsSnapshot) -> (labels: [Int: String], domain: [String], range: [Color]) {
        let unique = Set(lanes).sorted()
        var names = unique.map { laneName($0, snapshot) }
        if Set(names).count != names.count {
            names = zip(unique, names).map { "\($1) (ch \($0 + 1))" }
        }
        return (
            Dictionary(uniqueKeysWithValues: zip(unique, names)),
            names,
            unique.map { laneColor($0) }
        )
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

    private func overviewCard(_ snapshot: MetricsSnapshot, samples: [PipelineSample]) -> some View {
        let realtime = snapshot.realtimeCostTotal
        let assist = snapshot.assistCostTotal
        let billedMinutes = realtime / RealtimeLaneEngine.combinedDollarsPerSessionMinute
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
                tile("Duration", elapsedString(snapshot),
                     detail: liveDetail(snapshot, samples: samples))
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

    private func elapsedString(_ snapshot: MetricsSnapshot) -> String {
        guard let start = snapshot.sessionStartedAt else { return "—" }
        // The newest recorded timestamp, not Date(): a finished conversation
        // shows its actual length, and a live one updates at the 1 Hz tick.
        let total = max(0, (latestDataDate(snapshot) ?? start).timeIntervalSince(start))
        return Duration.seconds(total)
            .formatted(.time(pattern: total >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func liveDetail(_ snapshot: MetricsSnapshot, samples: [PipelineSample]) -> String {
        guard snapshot.isLive else { return "ended" }
        let open = samples.last?.openSessions ?? 0
        return "live · \(open) session\(open == 1 ? "" : "s") open"
    }

    // MARK: - Cost

    private func costCard(_ samples: [PipelineSample]) -> some View {
        card("Cost over time") {
            Text("Cumulative dollars: realtime audio sessions — translation ($\(String(format: "%.3f", RealtimeLaneEngine.dollarsPerSessionMinute))/min) plus source transcription (≈$\(String(format: "%.3f", RealtimeLaneEngine.transcriptionDollarsPerSessionMinute))/min) — vs prompter chat requests (estimated from token prices).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                pairedLineChart(
                    samples,
                    series: [("Realtime audio", \.realtimeCost), ("Prompter", \.assistCost)],
                    colors: [.indigo, .teal],
                    height: 160
                )
            }
        }
    }

    // MARK: - Latency

    private func latencyCard(_ snapshot: MetricsSnapshot, firstResponses: [FirstResponseSample], connects: [ConnectSample]) -> some View {
        card("Latency") {
            Text("First response — speech leaving the app until the first transcript or audio back (includes connect + queue flush for lazily-opened sessions).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(firstResponses, "No responses measured yet — they appear once speech gets translated.") {
                laneChart(scale: laneScale(firstResponses.map(\.lane), snapshot), height: 150) { labels in
                    Chart(firstResponses) { sample in
                        PointMark(
                            x: .value("Time", sample.date),
                            y: .value("Seconds", sample.seconds)
                        )
                        .symbolSize(45)
                        .foregroundStyle(by: .value("Speaker", labels[sample.lane] ?? "?"))
                    }
                }
            }
            Divider()
            Text("Connect — WebSocket open time per session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(connects, "No connections yet — sessions open on each speaker's first speech.") {
                laneChart(scale: laneScale(connects.map(\.lane), snapshot), height: 110) { labels in
                    Chart(connects) { sample in
                        PointMark(
                            x: .value("Time", sample.date),
                            y: .value("Seconds", sample.seconds)
                        )
                        .symbol(.diamond)
                        .symbolSize(45)
                        .foregroundStyle(by: .value("Speaker", labels[sample.lane] ?? "?"))
                    }
                }
            }
        }
    }

    /// Applies a lane color scale and frame to a scatter chart body.
    private func laneChart<C: View>(
        scale: (labels: [Int: String], domain: [String], range: [Color]),
        height: CGFloat,
        @ViewBuilder chart: ([Int: String]) -> C
    ) -> some View {
        chart(scale.labels)
            .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
            .frame(height: height)
    }

    // MARK: - Throughput

    private func throughputCard(_ samples: [PipelineSample]) -> some View {
        card("Throughput") {
            Text("Audio — seconds of audio per wall-clock second, all lanes summed (1.0 = one lane streaming continuously).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                pairedLineChart(
                    samples,
                    series: [("Mic → server", \.audioInRate), ("Translation ← server", \.audioOutRate)],
                    colors: [.teal, .indigo],
                    height: 140
                )
            }
            Divider()
            Text("Text — transcript characters received per second.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            chartOrPlaceholder(samples, "No samples yet.") {
                pairedLineChart(
                    samples,
                    series: [("Source text", \.sourceCharsPerSecond), ("Translation text", \.translationCharsPerSecond)],
                    colors: [.teal, .indigo],
                    height: 140
                )
            }
        }
    }

    /// Two (or more) PipelineSample series as labeled lines — the one shape
    /// behind the cost, audio, and text charts, so mark styling stays
    /// consistent across all three.
    private func pairedLineChart(
        _ samples: [PipelineSample],
        series: [(label: String, value: KeyPath<PipelineSample, Double>)],
        colors: [Color],
        height: CGFloat
    ) -> some View {
        Chart(samples) { sample in
            ForEach(series, id: \.label) { entry in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value(entry.label, sample[keyPath: entry.value]),
                    series: .value("Series", entry.label)
                )
                .foregroundStyle(by: .value("Series", entry.label))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.label), range: colors)
        .frame(height: height)
    }

    // MARK: - Sessions

    private func sessionsCard(_ samples: [PipelineSample]) -> some View {
        let maxSessions = max(samples.max(by: { $0.openSessions < $1.openSessions })?.openSessions ?? 1, 1)
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

    private func prompterCard(_ assistRequests: [AssistRequestSample]) -> some View {
        card("Prompter") {
            Text("Tokens per request — the prompt segment is the request's whole context (system + transcript window), so its trend is the context size. The gray segment is hidden reasoning: thinking tokens billed as output but never shown, the best proxy for reasoning effort per request.")
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
                        y: .value("Tokens", request.reasoningTokens),
                        width: .fixed(7)
                    )
                    .foregroundStyle(by: .value("Part", "Reasoning (hidden)"))
                    BarMark(
                        x: .value("Time", request.date),
                        y: .value("Tokens", max(0, request.completionTokens - request.reasoningTokens)),
                        width: .fixed(7)
                    )
                    .foregroundStyle(by: .value("Part", "Reply output"))
                }
                .chartForegroundStyleScale([
                    "Context (prompt)": Color.teal,
                    "Reasoning (hidden)": Color.gray,
                    "Reply output": Color.indigo
                ])
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
