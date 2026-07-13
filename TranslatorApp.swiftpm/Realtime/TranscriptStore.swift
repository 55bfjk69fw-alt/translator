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
        /// Pinyin of the texts above, cached at append time. The ICU
        /// transliteration is far too slow for render time — bubbles used
        /// to re-derive it on every status-bar meter tick.
        var sourcePinyin: String?
        var translatedPinyin: String?
        var isFinal: Bool
        var lastActivity: Date
        // The translation stream trails the source stream by 1-2 s, so the
        // two are tracked independently for segmentation.
        var lastSourceActivity: Date?
        var lastTranslationActivity: Date?
    }

    @Published private(set) var utterances: [Utterance] = []

    /// Monotonic count of utterances EVER finalized (never decremented by
    /// trim/clear). The prompter's ambient trigger diffs this — a live
    /// `filter(\.isFinal).count` plateaus at the trim cap and would silence
    /// the trigger for the rest of a long conversation.
    private(set) var finalizedTotal = 0

    /// Monotonic count of sentence boundaries seen in STREAMING deltas —
    /// the prompter's low-latency trigger: a completed sentence is worth
    /// suggesting on ~3 s before its utterance finalizes.
    private(set) var sentenceEventTotal = 0

    /// Fired (main thread) the moment a sentence boundary lands, so the
    /// prompter can react immediately instead of at the next 1 Hz tick.
    var onSentenceBoundary: (() -> Void)?

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "…", ".", "!", "?"]

    /// Closing quotes/brackets that legitimately trail a sentence ender
    /// ("……」" / ".\"") and must not hide it from the completeness check.
    private static let trailingClosers: Set<Character> = ["\"", "\u{201D}", "\u{2019}", "'", ")", "）", "」", "』", "]", "】"]

    /// True when the text's last meaningful character is a sentence ender —
    /// strong evidence the stream has delivered a complete thought.
    private func endsWithCompleteSentence(_ text: String) -> Bool {
        for char in text.reversed() {
            if char.isWhitespace || Self.trailingClosers.contains(char) { continue }
            return Self.sentenceEnders.contains(char)
        }
        return false
    }

    private func noteSentenceBoundary(in text: String) {
        guard text.contains(where: { Self.sentenceEnders.contains($0) }) else { return }
        sentenceEventTotal += 1
        onSentenceBoundary?()
    }

    /// Monotonic revision of visible transcript content. Bumped by every
    /// mutation that can change layout at the BOTTOM of the transcript
    /// (deltas, new bubbles, user utterances, finalization, clear) — but
    /// NOT by trim(), which removes rows from the front and must not
    /// re-trigger the transcript's pinned auto-scroll.
    private(set) var contentRevision = 0

    private let maxUtterances = 400

    /// Index of the open (partial) utterance per lane.
    private var openUtteranceIndex: [Int: Int] = [:]

    private enum Stream: String {
        case source, translation
    }

    /// The pinyin cache is filled at append time because the ICU
    /// transliteration is too slow for render time — but it re-derives the
    /// WHOLE accumulated string, and streaming deltas arrive many times per
    /// second, all on the main thread. Bound that: at most one recompute
    /// per stream per interval, with finalizeStale doing an unconditional
    /// last pass so the displayed pinyin can trail the text only while the
    /// bubble is visibly still streaming.
    private static let pinyinRecomputeInterval: TimeInterval = 0.3
    /// Last pinyin recompute per lane and stream. Cleared when a lane opens
    /// a fresh bubble so its first delta always computes immediately —
    /// pinyin must appear with the first characters, not 0.3 s later.
    private var lastPinyinComputeAt: [Int: [Stream: Date]] = [:]

    func appendSourceDelta(lane: Int, text: String) {
        reopenRecentIfNeeded(lane: lane, stream: .source)
        withOpenUtterance(lane: lane, stream: .source) {
            $0.sourceText += text
            $0.lastSourceActivity = Date()
        }
        recomputePinyinIfDue(lane: lane, stream: .source)
        noteSentenceBoundary(in: text)
    }

    func appendTranslationDelta(lane: Int, text: String) {
        reopenRecentIfNeeded(lane: lane, stream: .translation)
        withOpenUtterance(lane: lane, stream: .translation) {
            $0.translatedText += text
            $0.lastTranslationActivity = Date()
        }
        recomputePinyinIfDue(lane: lane, stream: .translation)
        noteSentenceBoundary(in: text)
    }

    private func recomputePinyinIfDue(lane: Int, stream: Stream) {
        guard let index = openUtteranceIndex[lane], utterances.indices.contains(index) else { return }
        let now = Date()
        if let last = lastPinyinComputeAt[lane]?[stream],
           now.timeIntervalSince(last) < Self.pinyinRecomputeInterval { return }
        lastPinyinComputeAt[lane, default: [:]][stream] = now
        switch stream {
        case .source:
            utterances[index].sourcePinyin = utterances[index].sourceText.pinyin
        case .translation:
            utterances[index].translatedPinyin = utterances[index].translatedText.pinyin
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
            sourcePinyin: source.pinyin,
            translatedPinyin: gloss.pinyin,
            isFinal: true,
            lastActivity: now,
            lastSourceActivity: now,
            lastTranslationActivity: now
        ))
        finalizedTotal += 1
        contentRevision += 1
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
    ///
    /// When both texts already end on a sentence boundary, the segment is
    /// almost certainly done, so `completedSentenceTimeout` (shorter) applies
    /// instead — fluid turn-taking was waiting out the full conservative
    /// window on bubbles that were visibly complete. A wrong call here is
    /// cheap: a trailing delta reattaches via reopenRecentIfNeeded.
    func finalizeStale(timeout: TimeInterval, completedSentenceTimeout: TimeInterval? = nil) {
        let now = Date()
        var finalizedAny = false
        for (lane, index) in openUtteranceIndex {
            guard utterances.indices.contains(index) else {
                openUtteranceIndex[lane] = nil
                continue
            }
            let utterance = utterances[index]
            let quietNeeded: TimeInterval
            if let fast = completedSentenceTimeout,
               endsWithCompleteSentence(utterance.sourceText),
               endsWithCompleteSentence(utterance.translatedText) {
                quietNeeded = fast
            } else {
                quietNeeded = timeout
            }
            let sourceQuiet = now.timeIntervalSince(utterance.lastSourceActivity ?? utterance.date) > quietNeeded
            let translationQuiet = now.timeIntervalSince(utterance.lastTranslationActivity ?? utterance.date) > quietNeeded
            let translationDrained = !utterance.translatedText.isEmpty
            let hardCap = now.timeIntervalSince(utterance.lastActivity) > timeout * 3
            if (sourceQuiet && translationQuiet && translationDrained) || hardCap {
                // Streaming recomputes are throttled, so the cached pinyin
                // can trail the text by a few deltas — the close is the
                // last write, and a final bubble must never show stale
                // pinyin.
                utterances[index].sourcePinyin = utterances[index].sourceText.pinyin
                utterances[index].translatedPinyin = utterances[index].translatedText.pinyin
                utterances[index].isFinal = true
                openUtteranceIndex[lane] = nil
                finalizedTotal += 1
                contentRevision += 1
                finalizedAny = true
                let reason = sourceQuiet && translationQuiet && translationDrained
                    ? (quietNeeded < timeout ? "sentence-quiet" : "quiet")
                    : "hard-cap"
                logFinalize(utterance, lane: lane, reason: reason)
            }
        }
        if finalizedAny { trim() }
    }

    func clear() {
        utterances.removeAll()
        openUtteranceIndex.removeAll()
        lastPinyinComputeAt.removeAll()
        contentRevision += 1
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
                sourcePinyin: nil,
                translatedPinyin: nil,
                isFinal: false,
                lastActivity: Date(),
                lastSourceActivity: nil,
                lastTranslationActivity: nil
            ))
            index = utterances.count - 1
            openUtteranceIndex[lane] = index
            lastPinyinComputeAt[lane] = nil
        }
        mutate(&utterances[index])
        utterances[index].lastActivity = Date()
        contentRevision += 1
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
