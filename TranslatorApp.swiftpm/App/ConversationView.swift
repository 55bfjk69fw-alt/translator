import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel

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
                pttBar
            }
            .navigationTitle("Translator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    startStopButton
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            ForEach(Array(model.lanes.enumerated()), id: \.element.id) { index, lane in
                LaneStatusDot(
                    lane: lane,
                    level: index < model.meters.count ? model.meters[index] : 0,
                    open: index < model.gateOpen.count ? model.gateOpen[index] : false,
                    state: model.sessionStates[lane.id]
                )
            }
            Spacer()
            if model.mode != .idle {
                Text(String(format: "~$%.2f", model.estimatedCost))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.transcript.utterances.isEmpty {
                        emptyHint
                    }
                    ForEach(model.transcript.utterances) { utterance in
                        UtteranceBubble(
                            utterance: utterance,
                            lane: model.lane(for: utterance.laneID),
                            playAction: utterance.translatedAudio != nil && model.mode != .idle
                                ? { model.playUtteranceAudio(utterance) }
                                : nil
                        )
                        .id(utterance.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.transcript.utterances.count) { _ in
                if let last = model.transcript.utterances.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
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

    // MARK: - Push to talk

    private var pttBar: some View {
        VStack(spacing: 4) {
            if model.speakerOverrideActive {
                Label("Playing Chinese over speaker", systemImage: "speaker.wave.2.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if model.mode == .pushToTalk {
                ProgressView(value: Double(model.pttLevel))
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .frame(maxWidth: 220)
            }
            PushToTalkButton(
                enabled: model.mode == .conversation || model.mode == .pushToTalk,
                isTalking: model.mode == .pushToTalk,
                onPress: { model.pttPressed() },
                onRelease: { model.pttReleased() }
            )
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}

// MARK: - Components

private struct LaneStatusDot: View {
    let lane: SpeakerLane
    let level: Float
    let open: Bool
    let state: RealtimeTranslationClient.State?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(lane.color.opacity(0.25))
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(lane.color)
                    .frame(width: CGFloat(8 + level * 18), height: CGFloat(8 + level * 18))
                    .opacity(open ? 1 : 0.45)
            }
            Text(lane.name)
                .font(.caption2)
                .lineLimit(1)
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
    let playAction: (() -> Void)?

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
                    if let playAction {
                        Button(action: playAction) {
                            Image(systemName: "speaker.wave.2.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !utterance.sourceText.isEmpty {
                    Text(utterance.sourceText)
                        .font(.body)
                }
                if !utterance.translatedText.isEmpty {
                    Text(utterance.translatedText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(lane.color.opacity(0.12))
            )
            if !isUser { Spacer(minLength: 60) }
        }
    }
}

private struct PushToTalkButton: View {
    let enabled: Bool
    let isTalking: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var pressing = false

    var body: some View {
        Label(
            isTalking ? "Speaking… (release to translate)" : "Hold to speak English",
            systemImage: "mic.fill"
        )
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(
            Capsule().fill(isTalking ? Color.red : (enabled ? Color.indigo : Color.gray))
        )
        .scaleEffect(isTalking ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isTalking)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !pressing else { return }
                    pressing = true
                    onPress()
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    onRelease()
                }
        )
    }
}
