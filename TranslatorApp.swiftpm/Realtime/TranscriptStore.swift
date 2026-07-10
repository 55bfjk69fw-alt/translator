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
        /// Set for staged-pipeline bubbles, which are keyed by the STT
        /// segment and finalized explicitly (nil = realtime bubble,
        /// finalized by the quiet timeout).
        var segmentID: UUID?
        /// Staged bubbles: false while the on-device recognizer may still
        /// revise the source text (drives the italic styling). The bubble
        /// itself stays open (isFinal == false) until translation/TTS done.
        var sourceSettled = true
    }

    @Published private(set) var utterances: [Utterance] = []

    private let maxUtterances = 400
    private let maxStoredAudioUtterances = 10

    /// Index of the open (partial) utterance per lane.
    private var openUtteranceIndex: [Int: Int] = [:]

    /// Index of staged-pipeline utterances by STT segment. Unlike
    /// openUtteranceIndex, several segments per lane can be live at once
    /// (segment N still translating while N+1's source streams).
    private var segmentIndex: [UUID: Int] = [:]

    private enum Stream: String {
        case source, translation, audio
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

    func appendTranslatedAudio(lane: Int, audio: Data) {
        reopenRecentIfNeeded(lane: lane, stream: .audio)
        withOpenUtterance(lane: lane, stream: .audio) {
            var existing = $0.translatedAudio ?? Data()
            existing.append(audio)
            $0.translatedAudio = existing
            $0.lastTranslationActivity = Date()
        }
    }

    // MARK: - Staged-pipeline segments (explicitly keyed and finalized)

    /// Source text for a staged STT segment. On-device STT revises earlier
    /// words as it listens, so the text REPLACES what the bubble held —
    /// unlike the realtime append-only deltas. `isFinal` means "source text
    /// settled", not "bubble done" — the bubble closes on finalizeSegment
    /// after translation/TTS.
    func upsertSegmentSource(lane: Int, segmentID: UUID, text: String, isFinal: Bool) {
        withSegmentUtterance(lane: lane, segmentID: segmentID) {
            $0.sourceText = text
            $0.sourceSettled = isFinal
            $0.lastSourceActivity = Date()
        }
    }

    /// Append a translated-text delta to a staged segment's bubble.
    func appendSegmentTranslation(lane: Int, segmentID: UUID, text: String) {
        withSegmentUtterance(lane: lane, segmentID: segmentID) {
            $0.translatedText += text
            $0.lastTranslationActivity = Date()
        }
    }

    /// Store the segment's translated audio so it can be replayed (used for
    /// the user's PTT lane, mirroring appendTranslatedAudio).
    func appendSegmentAudio(lane: Int, segmentID: UUID, audio: Data) {
        withSegmentUtterance(lane: lane, segmentID: segmentID) {
            // In-place append: pulling the Data out first would force a
            // full CoW copy of everything accumulated so far per chunk.
            if $0.translatedAudio == nil {
                $0.translatedAudio = audio
            } else {
                $0.translatedAudio?.append(audio)
            }
            $0.lastTranslationActivity = Date()
        }
    }

    /// Explicit staged finalization: the segment's translation stream (and
    /// TTS hand-off) is done.
    func finalizeSegment(_ segmentID: UUID, reason: String = "segment") {
        guard let index = segmentIndex[segmentID], utterances.indices.contains(index) else { return }
        utterances[index].isFinal = true
        utterances[index].sourceSettled = true
        segmentIndex[segmentID] = nil
        logFinalize(utterances[index], lane: utterances[index].laneID, reason: reason)
        trim()
    }

    /// Mutate (or open) the bubble for a staged segment with a single
    /// array write, so each event costs one objectWillChange.
    private func withSegmentUtterance(lane: Int, segmentID: UUID, _ mutate: (inout Utterance) -> Void) {
        let index = segmentUtteranceIndex(lane: lane, segmentID: segmentID)
        mutate(&utterances[index])
        utterances[index].lastActivity = Date()
    }

    /// Find (or open) the bubble for a staged segment. A late event for a
    /// segment already swept by the hard cap reattaches to its finalized
    /// bubble (found by segmentID) instead of opening a source-less orphan —
    /// the staged counterpart of reopenRecentIfNeeded.
    private func segmentUtteranceIndex(lane: Int, segmentID: UUID) -> Int {
        if let existing = segmentIndex[segmentID], utterances.indices.contains(existing) {
            return existing
        }
        if let finalized = utterances.lastIndex(where: { $0.segmentID == segmentID }) {
            Log.info("[transcript] lane \(lane): late segment event reattached to finalized bubble")
            utterances[finalized].isFinal = false
            segmentIndex[segmentID] = finalized
            return finalized
        }
        Log.info("[transcript] lane \(lane): new segment bubble opened")
        utterances.append(Utterance(
            laneID: lane,
            date: Date(),
            sourceText: "",
            translatedText: "",
            isFinal: false,
            translatedAudio: nil,
            lastActivity: Date(),
            lastSourceActivity: nil,
            lastTranslationActivity: nil,
            segmentID: segmentID,
            sourceSettled: false
        ))
        let index = utterances.count - 1
        segmentIndex[segmentID] = index
        return index
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
              // Segment bubbles are keyed and finalized explicitly — a late
              // realtime delta must never reopen one.
              utterances[lastIndex].segmentID == nil,
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
            let translationDrained = !utterance.translatedText.isEmpty || utterance.translatedAudio != nil
            let hardCap = now.timeIntervalSince(utterance.lastActivity) > timeout * 3
            if (sourceQuiet && translationQuiet && translationDrained) || hardCap {
                utterances[index].isFinal = true
                openUtteranceIndex[lane] = nil
                finalizedAny = true
                logFinalize(utterance, lane: lane, reason: sourceQuiet && translationQuiet && translationDrained ? "quiet" : "hard-cap")
            }
        }
        if finalizedAny { trim() }
        // Staged segments finalize explicitly, not on the quiet timeout —
        // but a stuck translation must not leave a bubble open forever, so
        // a long hard cap sweeps them as the safety net. Longer than the
        // worker's worst case (two 30 s translation attempts plus TTS), so
        // the sweep only fires for genuinely wedged segments; a late event
        // after the sweep reattaches via segmentUtteranceIndex.
        let segmentHardCap: TimeInterval = 120
        let staleSegments = segmentIndex.compactMap { segmentID, index -> UUID? in
            guard utterances.indices.contains(index) else { return segmentID }
            return now.timeIntervalSince(utterances[index].lastActivity) > segmentHardCap ? segmentID : nil
        }
        for segmentID in staleSegments {
            guard segmentIndex[segmentID].map(utterances.indices.contains) == true else {
                segmentIndex[segmentID] = nil
                continue
            }
            finalizeSegment(segmentID, reason: "segment-hard-cap")
        }
    }

    func clear() {
        utterances.removeAll()
        openUtteranceIndex.removeAll()
        segmentIndex.removeAll()
    }

    /// One WARN per half-empty bubble: these lines are the direct evidence
    /// for "Chinese characters missing" (translation, no source) and for the
    /// server never sending translation for a segment (source, no output).
    private func logFinalize(_ utterance: Utterance, lane: Int, reason: String) {
        let source = utterance.sourceText.count
        let translation = utterance.translatedText.count
        if source == 0, translation > 0 {
            Log.warn("[transcript] lane \(lane): finalized (\(reason)) with translation (\(translation)ch) but NO source text — Mandarin characters missing")
        } else if source > 0, translation == 0, utterance.translatedAudio == nil {
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
                translatedAudio: nil,
                lastActivity: Date(),
                lastSourceActivity: nil,
                lastTranslationActivity: nil,
                segmentID: nil
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
            segmentIndex = segmentIndex.compactMapValues { index in
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
