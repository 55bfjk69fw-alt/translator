import Foundation
import AVFoundation

// The per-lane pipeline seam (docs/CASCADE-PIPELINE.md §5.1): everything
// between "gated audio for one lane" and "transcript + translated audio
// out". AppModel talks to this protocol only; the realtime OpenAI path
// lives behind RealtimeLaneEngine, and the on-device cascade (CP2) will be
// a second implementation.

/// Lane lifecycle as the UI sees it (status dot, Diagnostics header).
/// Dot mapping: idle→gray, starting/reconnecting→yellow, running→green,
/// degraded→orange, failed→red.
enum LaneEngineState: Equatable {
    case idle
    case starting                       // connecting / warming up
    case running
    /// Running but impaired (e.g. cascade STT pool contention). The text
    /// is user-facing.
    case degraded(String)
    /// Realtime: closed, backoff timer armed for the given attempt.
    case reconnecting(attempt: Int)
    case failed(String)

    /// Publish guard for AppModel.sessionStates: `.reconnecting(3)` and
    /// `.reconnecting(4)` are the same dot, and today's same-value
    /// suppression must not re-publish on every retry
    /// (docs/CASCADE-PIPELINE.md §5.1). Attempt counts still reach
    /// Diagnostics via snapshot().
    func sameCase(as other: LaneEngineState) -> Bool {
        switch (self, other) {
        case (.idle, .idle), (.starting, .starting), (.running, .running),
             (.degraded, .degraded), (.reconnecting, .reconnecting),
             (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

/// Per-buffer gate outcome carried across the seam. The engine — not
/// AppModel — decides what suppressed audio becomes (realtime: silence
/// substitution to honor the continuous-timeline contract; cascade: drop).
struct GateVerdict {
    /// Hangover-smoothed "this lane is speaking" (pass && voiced — the
    /// conjunction AppModel keys lazy-open and idle-close on). Drives the
    /// realtime first-response clock.
    let speech: Bool
    /// Instantaneous genuine voicing (raw VAD minus bleed, pre-hangover;
    /// ChannelGate.Decision.genuineNow). The cascade closes utterances on
    /// a short debounce of this flag so the gate hangover never delays a
    /// translation (docs/CASCADE-PIPELINE.md §6.1).
    let voicedNow: Bool
    /// Gate pass (bleed-suppressed ⇒ false).
    let pass: Bool
}

/// One notice channel per lane so engines own their banner lifecycles —
/// raise AND retract — without clobbering unrelated errors: AppModel
/// clears a displayed banner only when the clearing id matches the one
/// that raised it (the reconnectBanner text-equality discipline, keyed).
enum LaneNotice {
    case raised(id: String, text: String)
    case cleared(id: String)
}

/// Transcript flow across the seam. The realtime path streams append-only
/// deltas (segmentation stays TranscriptStore's quiet-timeout); the
/// cascade path (CP2) replaces utterance text wholesale by UUID with
/// explicit finalization (docs/CASCADE-PIPELINE.md §7.1).
enum TranscriptEvent {
    case sourceDelta(String)
    case translationDelta(String)
    case sourceText(utterance: UUID, text: String, isFinal: Bool)
    case translationText(utterance: UUID, text: String, isFinal: Bool)
}

/// Per-stage latency measurements, forwarded to MetricsStore.
enum LaneMetric {
    case connectSeconds(Double)          // realtime: WS connect
    case firstResponseSeconds(Double)    // realtime: speech → first content
    case sttFinalizeSeconds(Double)      // cascade: close-request → final text (excludes the debounce)
    case translationSeconds(Double)      // cascade: final text → translation
    case ttsFirstAudioSeconds(Double)    // cascade: translation → first PCM
    case endToEndSeconds(Double)         // cascade: speech-end → first PCM
}

/// Diagnostics snapshot, rendered per-kind by the pipeline panel.
enum LaneEngineSnapshot {
    case realtime(RealtimeTranslationClient.Snapshot)
    case cascade(CascadeSnapshot)
}

/// Cascade per-lane counters for the Diagnostics pipeline panel
/// (docs/CASCADE-PIPELINE.md §9). CP2 renders the essentials; CP3 grows
/// the symptom lines.
struct CascadeSnapshot {
    var state: LaneEngineState
    /// Utterances opened / finalized / translated / spoken this
    /// conversation — the four stages' progress at a glance.
    var utterancesOpened: Int
    var utterancesFinalized: Int
    var utterancesTranslated: Int
    var utterancesSpoken: Int
    var volatileChars: Int
    var finalChars: Int
    /// Pool contention evidence.
    var slotWaits: Int
    var lastSlotWaitSeconds: Double?
    var holdsSlot: Bool
    /// Seconds of audio buffered lane-side while waiting for a slot.
    var bufferedAudioSeconds: Double
    /// Audio jobs skipped by backpressure (transcript kept, speech
    /// dropped).
    var audioSkips: Int
    /// Last measured stage latencies (nil until first measurement).
    var lastFinalizeSeconds: Double?
    var lastTranslateSeconds: Double?
    var lastTTSFirstAudioSeconds: Double?
    var lastError: String?
}

/// One instance per lane per conversation. Lifecycle is pipeline-dependent
/// (docs/CASCADE-PIPELINE.md §5.1): realtime engines are opened lazily on
/// first speech and idle-closed (they bound billing); cascade engines open
/// eagerly at Start and stay open (closing is terminal and re-opening
/// re-pays warm-up).
protocol LaneEngine: AnyObject {
    var label: String { get }

    /// Called on audioQueue for EVERY tap buffer (hardware-rate mono
    /// float32) with the gate's verdicts. The engine owns its converters
    /// and MUST compare `buffer.format` against its converter's input on
    /// every call, rebuilding on change: route churn (USB replug, BT codec
    /// renegotiation) changes the hardware rate mid-conversation, and a
    /// stale converter in a cascade STT path fails SILENTLY. (AppModel no
    /// longer rebuilds resamplers on route change — that responsibility
    /// lives behind this seam now.)
    func sendAudio(_ buffer: AVAudioPCMBuffer, verdict: GateVerdict)

    func start()
    /// Terminal. Bounds any internal retry chain; billing/cost callbacks
    /// keep flowing through the close drain (see onCostDelta).
    func close()

    // Callbacks fire on the engine's private queue; consumers hop to main
    // as needed (CostMeter is thread-safe and is the exception).
    var onState: ((LaneEngineState) -> Void)? { get set }
    var onNotice: ((LaneNotice) -> Void)? { get set }
    var onTranscript: ((TranscriptEvent) -> Void)? { get set }
    /// 24 kHz mono PCM16 LE — the existing playback seam
    /// (EngineGraph.schedule via AppModel.playEnglishAudio).
    var onTranslatedAudio: ((Data) -> Void)? { get set }
    /// Monotonic dollar increments. Deliberately NOT identity-guarded by
    /// AppModel: an engine evicted at idle-close keeps this callback alive
    /// through its close drain so drained audio still bills — the
    /// onBilledSeconds contract, moved behind the seam with the pricing.
    var onCostDelta: ((Double) -> Void)? { get set }
    var onMetric: ((LaneMetric) -> Void)? { get set }

    /// Point-in-time counters for the Diagnostics pipeline panel; sampled
    /// at 1 Hz from the main thread.
    func snapshot() -> LaneEngineSnapshot
}
