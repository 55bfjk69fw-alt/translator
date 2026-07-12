import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    /// Observed directly (not through AppModel) so streaming deltas only
    /// re-render the transcript-reading parts of this view.
    @EnvironmentObject private var transcript: TranscriptStore

    @State private var composerText = ""
    @State private var composing = false
    @State private var cueCard: AssistEngine.Suggestion?
    @State private var explanation: AssistEngine.Explanation?
    @State private var confirmingClear = false

    /// The privacy switch: with the prompter off, NO assist affordance may
    /// exist — the composer, tray, and long-press actions all send the
    /// transcript window + bio to OpenAI (the engine also guards, but the
    /// UI must not offer what the setting promises is off).
    @AppStorage(AppSettings.prompterEnabledKey) private var prompterEnabled = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if let banner = model.errorBanner {
                    Text(banner)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.red)
                }
                transcriptList
                    // Dragging the transcript tucks the keyboard away with
                    // the finger (Messages-style); a plain tap on it does
                    // too. simultaneousGesture so bubble long-presses and
                    // the jump-to-latest pill keep working untouched.
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                if prompterEnabled {
                    AssistBarView(
                        assist: model.assist,
                        composerText: $composerText,
                        composing: composing,
                        conversationActive: model.mode == .conversation,
                        onOpenCard: { cueCard = $0 },
                        onCompose: composeDraft
                    )
                }
            }
            .navigationTitle("Translator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    clearButton
                }
                ToolbarItem(placement: .primaryAction) {
                    startStopButton
                }
            }
            .confirmationDialog(
                "Clear the conversation?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear conversation", role: .destructive) {
                    transcript.clear()
                }
            } message: {
                Text("Removes every bubble from the transcript. This can't be undone.")
            }
            .sheet(item: $cueCard) { suggestion in
                CueCardView(
                    suggestion: suggestion,
                    onSaid: {
                        model.assist.markSaid(suggestion)
                        cueCard = nil
                    },
                    onRefine: {
                        composerText = suggestion.gloss
                        cueCard = nil
                    }
                )
            }
            .sheet(item: $explanation) { explanation in
                ExplainCardView(explanation: explanation)
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        StatusBarView(
            meters: model.channelMeters,
            lanes: model.lanes,
            sessionStates: model.sessionStates,
            estimatedCost: model.estimatedCost,
            showCost: model.mode != .idle
        )
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            confirmingClear = true
        } label: {
            Label("Clear conversation", systemImage: "trash")
        }
        .disabled(transcript.utterances.isEmpty)
    }

    private var startStopButton: some View {
        Button {
            if model.mode == .idle {
                model.startConversation()
            } else {
                model.stopConversation()
            }
        } label: {
            Label(
                model.mode == .idle ? "Start" : "Stop",
                systemImage: model.mode == .idle ? "play.fill" : "stop.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(model.mode == .idle ? .green : .red)
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        PinnedScrollView(
            bottomID: transcript.utterances.last?.id,
            contentRevision: transcript.contentRevision,
            itemCount: transcript.utterances.count
        ) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if transcript.utterances.isEmpty {
                    emptyHint
                }
                ForEach(transcript.utterances) { utterance in
                    let isUser = utterance.laneID == SpeakerLane.userLaneID
                    UtteranceBubble(
                        utterance: utterance,
                        lane: model.lane(for: utterance.laneID),
                        onReplyTo: prompterEnabled && !isUser && utterance.isFinal
                            ? { requestScopedReply(to: utterance) }
                            : nil,
                        onExplain: prompterEnabled && !isUser && !utterance.sourceText.isEmpty
                            ? { explain(utterance) }
                            : nil
                    )
                    .id(utterance.id)
                }
            }
            .padding()
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Plug in the DJI receiver (Quadraphonic mode), connect AirPods, then tap Start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Prompter actions

    private func composeDraft() {
        let draft = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !composing else { return }
        composing = true
        Task { @MainActor in
            let suggestion = await model.assist.compose(draft: draft)
            composing = false
            if let suggestion {
                composerText = ""
                cueCard = suggestion
            }
        }
    }

    private func requestScopedReply(to utterance: TranscriptStore.Utterance) {
        model.assist.requestScoped(
            speaker: model.laneName(utterance.laneID),
            source: utterance.sourceText,
            translation: utterance.translatedText
        )
    }

    private func explain(_ utterance: TranscriptStore.Utterance) {
        let speaker = model.laneName(utterance.laneID)
        Task { @MainActor in
            if let result = await model.assist.explain(
                speaker: speaker,
                source: utterance.sourceText,
                translation: utterance.translatedText
            ) {
                explanation = result
            }
        }
    }
}

// MARK: - Status bar

/// Observes ChannelMeters directly so the 10 Hz level churn re-renders only
/// this bar — not the transcript list above the fold.
private struct StatusBarView: View {
    @ObservedObject var meters: ChannelMeters
    let lanes: [SpeakerLane]
    let sessionStates: [Int: RealtimeTranslationClient.State]
    let estimatedCost: Double
    let showCost: Bool

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                LaneStatusDot(
                    lane: lane,
                    level: index < meters.levels.count ? meters.levels[index] : 0,
                    open: index < meters.gateOpen.count ? meters.gateOpen[index] : false,
                    state: sessionStates[lane.id]
                )
            }
            Spacer()
            if showCost {
                Text(String(format: "~$%.2f", estimatedCost))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

// MARK: - Assist bar

/// Scene chip + suggestion tray + composer: the reply flow's home
/// (docs/REPLY-FLOW.md §2). Observes the AssistEngine directly so
/// suggestion churn doesn't re-render the transcript above it.
private struct AssistBarView: View {
    @ObservedObject var assist: AssistEngine
    @Binding var composerText: String
    let composing: Bool
    let conversationActive: Bool
    let onOpenCard: (AssistEngine.Suggestion) -> Void
    let onCompose: () -> Void

    @AppStorage(AppSettings.sceneContextKey) private var scene = ""
    @State private var editingScene = false
    @State private var sceneDraft = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                sceneChip
                Spacer()
                statusIndicator
                if conversationActive {
                    Button {
                        assist.requestNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if !assist.suggestions.isEmpty {
                // Wrapping flow, not a horizontal scroller: every chip is
                // visible at a glance — scanning beats scrolling at a
                // chaotic table.
                FlowLayout(spacing: 8) {
                    ForEach(assist.suggestions) { suggestion in
                        SuggestionChip(
                            suggestion: suggestion,
                            onTap: { onOpenCard(suggestion) },
                            onTogglePin: { assist.togglePin(suggestion.id) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                // Single-line on purpose: with axis .vertical the Return
                // key inserts a newline and .onSubmit never fires.
                TextField("Compose a reply to say aloud…", text: $composerText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    // The keyboard's own escape hatch: Return sends rather
                    // than dismissing, so without this bar a stray tap into
                    // the composer leaves no way to put the keyboard away.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { dismissKeyboard() }
                        }
                    }
                if composing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .alert("Set the scene", isPresented: $editingScene) {
            TextField("Dinner with the in-laws in Chengdu…", text: $sceneDraft)
            Button("Save") { scene = sceneDraft }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One line of context that makes suggestions land — where you are, who's at the table, what's going on.")
        }
    }

    /// Sending opens the cue-card sheet, so drop the keyboard first —
    /// otherwise it's still standing under the sheet when the card closes.
    private func submit() {
        dismissKeyboard()
        onCompose()
    }

    private var sceneChip: some View {
        Button {
            sceneDraft = scene
            editingScene = true
        } label: {
            Label(scene.isEmpty ? "Set the scene…" : scene, systemImage: "theatermasks")
                .font(.caption)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch assist.status {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .offline:
            Label("prompter offline", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

private struct SuggestionChip: View {
    let suggestion: AssistEngine.Suggestion
    let onTap: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if suggestion.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                    }
                    Text(suggestion.gloss)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text(suggestion.replyTo.map { "→ \($0)" } ?? "→ table")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Bound the chip so one long gloss can't blow past the row
            // width in the flow layout; the full text lives on the card.
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.indigo.opacity(suggestion.pinned ? 0.22 : 0.12))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onTogglePin) {
                Label(suggestion.pinned ? "Unpin" : "Pin", systemImage: suggestion.pinned ? "pin.slash" : "pin")
            }
        }
    }
}

/// Minimal left-aligned wrapping layout (iOS 16 Layout protocol): chips
/// flow onto new rows instead of scrolling off-screen.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAdded = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if widthIfAdded > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.width = size.width
            } else {
                current.width = widthIfAdded
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

// MARK: - Cue card

/// The thing the user reads aloud. Hanzi big enough to read at arm's
/// length, pinyin as the pronunciation aid, gloss so they know exactly
/// what they're committing to. Never enters the transcript unless
/// confirmed via "I said this".
private struct CueCardView: View {
    let suggestion: AssistEngine.Suggestion
    let onSaid: () -> Void
    let onRefine: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            // The intent (what the chip showed) as a small anchor…
            Text(suggestion.gloss)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 4)
            Text(suggestion.hanzi)
                .font(.system(size: 40, weight: .semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if !suggestion.pinyin.isEmpty {
                Text(suggestion.pinyin)
                    .font(.title2)
                    .foregroundStyle(.teal)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            // …and the LITERAL meaning of the exact line, so the user
            // knows precisely what they're committing to say.
            Text("“\(suggestion.meaning)”")
                .font(.title3)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                tag(suggestion.register)
                if let replyTo = suggestion.replyTo {
                    tag("→ \(replyTo)")
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                Button(action: onSaid) {
                    Label("I said this", systemImage: "checkmark.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.indigo)
                Button(action: onRefine) {
                    Label("Refine…", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Explain card

private struct ExplainCardView: View {
    let explanation: AssistEngine.Explanation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(explanation.about)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(explanation.explanation)
                    .font(.body)
                ForEach(explanation.phrases) { phrase in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phrase.hanzi)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text(phrase.pinyin)
                            .font(.subheadline.italic())
                            .foregroundStyle(.teal)
                        Text(phrase.meaning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Components

private struct LaneStatusDot: View {
    let lane: SpeakerLane
    let level: Float
    let open: Bool
    let state: RealtimeTranslationClient.State?
    @AppStorage private var enabled: Bool

    init(lane: SpeakerLane, level: Float, open: Bool, state: RealtimeTranslationClient.State?) {
        self.lane = lane
        self.level = level
        self.open = open
        self.state = state
        _enabled = AppStorage(wrappedValue: true, AppSettings.speakerEnabledKey(lane.id))
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(lane.color.opacity(0.25))
                    .frame(width: 26, height: 26)
                if enabled {
                    Circle()
                        .fill(lane.color)
                        .frame(width: CGFloat(8 + level * 18), height: CGFloat(8 + level * 18))
                        .opacity(open ? 1 : 0.45)
                } else {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text(lane.name)
                .font(.caption2)
                .lineLimit(1)
                .opacity(enabled ? 1 : 0.4)
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
        }
    }

    private var stateColor: Color {
        switch state {
        case .open: return .green
        case .connecting: return .yellow
        case .closed: return .red
        case .idle, nil: return .gray
        }
    }
}

private struct UtteranceBubble: View {
    let utterance: TranscriptStore.Utterance
    let lane: SpeakerLane
    let onReplyTo: (() -> Void)?
    let onExplain: (() -> Void)?

    @AppStorage(AppSettings.showPinyinKey) private var showPinyin = true

    private var isUser: Bool { utterance.laneID == SpeakerLane.userLaneID }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(lane.name)
                        .font(.caption.bold())
                        .foregroundStyle(lane.color)
                    Text(utterance.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !utterance.isFinal {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                if !utterance.sourceText.isEmpty {
                    Text(utterance.sourceText)
                        .font(.body)
                    if showPinyin, let pinyin = utterance.sourcePinyin {
                        Text(pinyin)
                            .font(.footnote.italic())
                            .foregroundStyle(.teal)
                            .textSelection(.enabled)
                    }
                }
                if !utterance.translatedText.isEmpty {
                    Text(utterance.translatedText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if showPinyin, let pinyin = utterance.translatedPinyin {
                        Text(pinyin)
                            .font(.footnote.italic())
                            .foregroundStyle(.teal)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(lane.color.opacity(0.12))
            )
            .contextMenu {
                if let onReplyTo {
                    Button(action: onReplyTo) {
                        Label("Reply to this", systemImage: "arrowshape.turn.up.left")
                    }
                }
                if let onExplain {
                    Button(action: onExplain) {
                        Label("Explain this", systemImage: "questionmark.bubble")
                    }
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }
}
