import Foundation
import SwiftUI

/// One speaker lane = one audio channel = one translation session.
struct SpeakerLane: Identifiable {
    let id: Int            // channel index; -1 is the push-to-talk user lane
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
        /// 24 kHz PCM16 of the translated audio (kept only for the user's
        /// ZH utterances so they can be replayed over the speaker).
        var translatedAudio: Data?
        var lastActivity: Date
        // The translation stream trails the source stream by 1-2 s, so the
        // two are tracked independently for segmentation.
        var lastSourceActivity: Date?
        var lastTranslationActivity: Date?
    }

    @Published private(set) var utterances: [Utterance] = []

    private let maxUtterances = 400
    private let maxStoredAudioUtterances = 10

    /// Index of the open (partial) utterance per lane.
    private var openUtteranceIndex: [Int: Int] = [:]

    func appendSourceDelta(lane: Int, text: String) {
        withOpenUtterance(lane: lane) {
            $0.sourceText += text
            $0.lastSourceActivity = Date()
        }
    }

    func appendTranslationDelta(lane: Int, text: String) {
        reopenRecentIfNeeded(lane: lane)
        withOpenUtterance(lane: lane) {
            $0.translatedText += text
            $0.lastTranslationActivity = Date()
        }
    }

    func appendTranslatedAudio(lane: Int, audio: Data, keepAudio: Bool) {
        guard keepAudio else { return }
        reopenRecentIfNeeded(lane: lane)
        withOpenUtterance(lane: lane) {
            var existing = $0.translatedAudio ?? Data()
            existing.append(audio)
            $0.translatedAudio = existing
            $0.lastTranslationActivity = Date()
        }
    }

    /// Translation output trails the source; if a translation delta arrives
    /// just after its bubble was finalized, reattach it to that bubble
    /// instead of opening an orphan bubble with no source text.
    private func reopenRecentIfNeeded(lane: Int) {
        guard openUtteranceIndex[lane] == nil,
              let lastIndex = utterances.lastIndex(where: { $0.laneID == lane }),
              utterances[lastIndex].isFinal,
              Date().timeIntervalSince(utterances[lastIndex].lastActivity) < 6 else { return }
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
            let translationDrained = !utterance.translatedText.isEmpty || utterance.translatedAudio != nil
            let hardCap = now.timeIntervalSince(utterance.lastActivity) > timeout * 3
            if (sourceQuiet && translationQuiet && translationDrained) || hardCap {
                utterances[index].isFinal = true
                openUtteranceIndex[lane] = nil
                finalizedAny = true
            }
        }
        if finalizedAny { trim() }
    }

    func clear() {
        utterances.removeAll()
        openUtteranceIndex.removeAll()
    }

    private func withOpenUtterance(lane: Int, _ mutate: (inout Utterance) -> Void) {
        let index: Int
        if let existing = openUtteranceIndex[lane], utterances.indices.contains(existing), !utterances[existing].isFinal {
            index = existing
        } else {
            utterances.append(Utterance(
                laneID: lane,
                date: Date(),
                sourceText: "",
                translatedText: "",
                isFinal: false,
                translatedAudio: nil,
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
        // Bound memory: cap utterance count and drop old stored audio.
        if utterances.count > maxUtterances {
            let overflow = utterances.count - maxUtterances
            utterances.removeFirst(overflow)
            openUtteranceIndex = openUtteranceIndex.compactMapValues { index in
                let shifted = index - overflow
                return shifted >= 0 ? shifted : nil
            }
        }
        var audioSeen = 0
        for index in utterances.indices.reversed() where utterances[index].translatedAudio != nil {
            audioSeen += 1
            if audioSeen > maxStoredAudioUtterances {
                utterances[index].translatedAudio = nil
            }
        }
    }
}
