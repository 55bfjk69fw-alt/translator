import Foundation

/// Connection state shared by every lane-session implementation (the
/// realtime WebSocket client and the staged on-device pipeline).
enum LaneSessionState: Equatable {
    case idle
    case connecting
    case open
    case closed(String?)
}

/// One translation session for one speaker lane: continuous 24 kHz mono
/// PCM16 in, transcripts and translated audio out. AppModel holds one per
/// lane and doesn't care which pipeline is behind it.
///
/// Two transcript delivery styles share this surface:
///  - The realtime client emits append-only deltas with no segment
///    boundaries (`onSourceTranscriptDelta`/`onTranslatedTranscriptDelta`);
///    segmentation is the consumer's job (quiet timeout in TranscriptStore).
///  - The staged client emits segment-keyed events: on-device STT revises
///    earlier words, so volatile source text REPLACES the segment's text
///    (`onSegmentSource`), translations append per segment, and completion
///    is explicit. A client uses one style or the other, never both.
protocol TranslationLaneSession: AnyObject {
    var label: String { get }

    var onStateChange: ((LaneSessionState) -> Void)? { get set }
    /// Append-only source-language transcript delta (realtime style).
    var onSourceTranscriptDelta: ((String) -> Void)? { get set }
    /// Append-only translated transcript delta (realtime style).
    var onTranslatedTranscriptDelta: ((String) -> Void)? { get set }
    /// 24 kHz mono PCM16 little-endian audio of the translated speech.
    var onTranslatedAudio: ((Data) -> Void)? { get set }
    /// Incremental billed-audio seconds ($0.034/min realtime billing).
    var onBilledSeconds: ((Double) -> Void)? { get set }

    /// Segment-keyed source text (staged style): the FULL text so far for
    /// the segment — replaces, not appends. `isFinal` marks the last
    /// revision (the text that gets translated).
    var onSegmentSource: ((_ segmentID: UUID, _ fullText: String, _ isFinal: Bool) -> Void)? { get set }
    /// Segment-keyed translated-text delta (append within the segment).
    var onSegmentTranslation: ((_ segmentID: UUID, _ delta: String) -> Void)? { get set }
    /// Segment-keyed translated audio (24 kHz mono PCM16 LE). The staged
    /// client emits audio here instead of `onTranslatedAudio` so the
    /// consumer can both play it and attach it to the right bubble.
    var onSegmentAudio: ((_ segmentID: UUID, _ audio: Data) -> Void)? { get set }
    /// The segment's translation stream (and any TTS hand-off) is done.
    var onSegmentCompleted: ((_ segmentID: UUID) -> Void)? { get set }
    /// Non-realtime cost increments in dollars (translation tokens, TTS
    /// characters). Estimates; the realtime client bills via
    /// `onBilledSeconds` instead.
    var onCostDollars: ((Double) -> Void)? { get set }

    func connect()
    func close()
    /// Append 24 kHz mono PCM16 little-endian audio. Called from
    /// AppModel's audio queue; must be cheap and thread-safe.
    func sendAudio(_ pcm16: Data)
}
