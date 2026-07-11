import Foundation
import SwiftUI

/// One speaker lane = one audio channel = one translation session.
struct SpeakerLane: Identifiable {
    let id: Int            // channel index; -1 is the user's own lane
    var name: String
    var color: Color

    static let laneColors: [Color] = [.blue, .green, .orange, .purple]

    static func djiLane(channel: Int, name: String? = nil) -> SpeakerLane {
        SpeakerLane(
            id: channel,
            name: name ?? "Speaker \(channel + 1)",
            color: laneColors[channel % laneColors.count]
        )
    }

    static let userLaneID = -1

    static func userLane(name: String = "Me") -> SpeakerLane {
        SpeakerLane(id: userLaneID, name: name, color: .indigo)
    }
}

/// Rolling conversation transcript. Translation sessions stream continuous
/// deltas; an utterance is finalized when the session reports the transcript
/// segment done, or after a quiet timeout (handled by AppModel's tick).
/// Must only be touched on the main thread (all callers hop there first).
final class TranscriptStore: ObservableObject {

    struct Utterance: Identifiable {
        let id = UUID()
        let laneID: Int
        let date: Date
        var sourceText: String
        var translatedText: String
        var isFinal: Bool
        var lastActivity: Date
        // The translation stream trails the source stream by 1-2 s, so the
        // two are tracked independently for segmentation.
        var lastSourceActivity: Date?
        var lastTranslationActivity: Date?
    }

    @Published private(set) var utterances: [Utterance] = []

    private let maxUtterances = 400

    /// Index of the open (partial) utterance per lane.
    private var openUtteranceIndex: [Int: Int] = [:]

    private enum Stream: String {
        case source, translation
    }

    func appendSourceDelta(lane: Int, text: String) {
        reopenRecentIfNeeded(lane: lane, stream: .source)
        withOpenUtterance(lane: lane, stream: .source) {
            $0.sourceText += text
            $0.lastSourceActivity = Date()
        }
    }

    func appendTranslationDelta(lane: Int, text: String) {
        reopenRecentIfNeeded(lane: lane, stream: .translation)
        withOpenUtterance(lane: lane, stream: .translation) {
            $0.translatedText += text
            $0.lastTranslationActivity = Date()
        }
    }

    /// Record something the user actually said aloud (a cue card confirmed
    /// via "I said this"). Final immediately — no server stream ever feeds
    /// the user lane, so there is nothing to wait for.
    func addUserUtterance(source: String, gloss: String) {
        let now = Date()
        utterances.append(Utterance(
            laneID: SpeakerLane.userLaneID,
            date: now,
            sourceText: source,
            translatedText: gloss,
            isFinal: true,
            lastActivity: now,
            lastSourceActivity: now,
            lastTranslationActivity: now
        ))
        trim()
    }

    /// The two server streams are not in lockstep: translation output trails
    /// the source, and the source (whisper) transcript can arrive as a burst
    /// AFTER the translation is done. If a late delta arrives just after its
    /// bubble was finalized, reattach it to that bubble instead of opening an
    /// orphan bubble carrying only half the content.
    ///
    /// A late SOURCE delta only reattaches to a bubble still missing its
    /// source text — a finalized bubble that already has Chinese means new
    /// speech started, which deserves a fresh bubble. (This is the fix for
    /// English-only bubbles: the late Chinese burst used to open a sourceless
    /// orphan instead of filling in the bubble the user is looking at.)
    private func reopenRecentIfNeeded(lane: Int, stream: Stream) {
        let window: TimeInterval = stream == .source ? 10 : 6
        guard openUtteranceIndex[lane] == nil,
              let lastIndex = utterances.lastIndex(where: { $0.laneID == lane }),
              utterances[lastIndex].isFinal,
              Date().timeIntervalSince(utterances[lastIndex].lastActivity) < window else { return }
        if stream == .source, !utterances[lastIndex].sourceText.isEmpty { return }
        Log.info("[transcript] lane \(lane): late \(stream.rawValue) delta reattached to finalized bubble")
        utterances[lastIndex].isFinal = false
        openUtteranceIndex[lane] = lastIndex
    }

    /// Finalize any lane whose open utterance has gone quiet. This is the
    /// ONLY segmentation mechanism by design: translation sessions emit
    /// append-only deltas with no done/boundary events.
    ///
    /// Source and translation streams are judged independently — the
    /// translation trails by 1-2 s, and finalizing on overall inactivity
    /// truncated translations mid-sentence and spilled the remainder into
    /// sourceless bubbles. A bubble closes only when BOTH streams are quiet
    /// and a translation has arrived, or after a hard cap (some segments
    /// never get transcript deltas).
    func finalizeStale(timeout: TimeInterval) {
        let now = Date()
        var finalizedAny = false
        for (lane, index) in openUtteranceIndex {
            guard utterances.indices.contains(index) else {
                openUtteranceIndex[lane] = nil
                continue
            }
            let utterance = utterances[index]
            let sourceQuiet = now.timeIntervalSince(utterance.lastSourceActivity ?? utterance.date) > timeout
            let translationQuiet = now.timeIntervalSince(utterance.lastTranslationActivity ?? utterance.date) > timeout
            let translationDrained = !utterance.translatedText.isEmpty
            let hardCap = now.timeIntervalSince(utterance.lastActivity) > timeout * 3
            if (sourceQuiet && translationQuiet && translationDrained) || hardCap {
                utterances[index].isFinal = true
                openUtteranceIndex[lane] = nil
                finalizedAny = true
                logFinalize(utterance, lane: lane, reason: sourceQuiet && translationQuiet && translationDrained ? "quiet" : "hard-cap")
            }
        }
        if finalizedAny { trim() }
    }

    func clear() {
        utterances.removeAll()
        openUtteranceIndex.removeAll()
    }

    /// One WARN per half-empty bubble: these lines are the direct evidence
    /// for "Chinese characters missing" (translation, no source) and for the
    /// server never sending translation for a segment (source, no output).
    private func logFinalize(_ utterance: Utterance, lane: Int, reason: String) {
        let source = utterance.sourceText.count
        let translation = utterance.translatedText.count
        if source == 0, translation > 0 {
            Log.warn("[transcript] lane \(lane): finalized (\(reason)) with translation (\(translation)ch) but NO source text — Mandarin characters missing")
        } else if source > 0, translation == 0 {
            Log.warn("[transcript] lane \(lane): finalized (\(reason)) with source (\(source)ch) but NO translation output")
        } else {
            Log.info("[transcript] lane \(lane): finalized (\(reason)) source=\(source)ch translation=\(translation)ch")
        }
    }

    private func withOpenUtterance(lane: Int, stream: Stream, _ mutate: (inout Utterance) -> Void) {
        let index: Int
        if let existing = openUtteranceIndex[lane], utterances.indices.contains(existing), !utterances[existing].isFinal {
            index = existing
        } else {
            Log.info("[transcript] lane \(lane): new bubble opened by \(stream.rawValue) stream")
            utterances.append(Utterance(
                laneID: lane,
                date: Date(),
                sourceText: "",
                translatedText: "",
                isFinal: false,
                lastActivity: Date(),
                lastSourceActivity: nil,
                lastTranslationActivity: nil
            ))
            index = utterances.count - 1
            openUtteranceIndex[lane] = index
        }
        mutate(&utterances[index])
        utterances[index].lastActivity = Date()
    }

    private func trim() {
        // Bound memory: cap utterance count.
        if utterances.count > maxUtterances {
            let overflow = utterances.count - maxUtterances
            utterances.removeFirst(overflow)
            openUtteranceIndex = openUtteranceIndex.compactMapValues { index in
                let shifted = index - overflow
                return shifted >= 0 ? shifted : nil
            }
        }
    }
}
