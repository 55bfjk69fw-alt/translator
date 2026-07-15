# Cascade pipeline: modular STT → translation → TTS (design)

Status: **design, reviewed** — LGTM after three adversarial review
rounds (research claims independently re-verified against primary
sources; design checked against the actual codebase). Nothing here is
implemented yet; implementation starts at CP0 (§10/§11).
Research date: 2026-07-14. Companion to `docs/RESEARCH.md` (the realtime
pipeline's feasibility research); this document covers the alternative
*cascade* pipeline and the provider abstraction behind it.

## 1. What this is

Today the app has exactly one translation engine: one OpenAI
`gpt-realtime-translate` WebSocket per mic channel (speech in → translated
speech + transcripts out, monolithic). This design adds a second,
selectable pipeline that decomposes the job into three independently
swappable stages:

- **STT** — Apple `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26, on-device,
  offline once the zh model is downloaded) first; OpenAI streaming
  transcription later.
- **Translation** — Apple's Translation framework (the same engine the
  Translate app uses, offline with downloaded language packs) first;
  OpenAI/DeepL later.
- **TTS** — Apple `AVSpeechSynthesizer` (on-device voices, offline) first;
  OpenAI/ElevenLabs later — with **a configurable voice per speaker lane**
  so the listener can tell speakers apart.

Everything the multi-mic system already does is kept unchanged: per-channel
Silero-VAD gating with bleed rejection, lazy per-lane sessions, per-lane
playback nodes with overlap ducking, the Signal/Metrics/Diagnostics
tooling, and the reply prompter.

### Goals

1. A working all-Apple cascade: free, offline-capable, no API key.
2. A provider seam that the future OpenAI (and ElevenLabs/DeepL) stage
   implementations drop into without another refactor.
3. Per-lane TTS voice configuration (distinct voices by default).
4. The realtime OpenAI pipeline remains the default and is untouched
   behaviorally; the pipeline choice is a Settings toggle.

### Non-goals (this iteration)

- Mixing providers *within* one conversation stage-by-stage UI (the
  architecture supports it; the UI exposes one provider per stage).
- Reverse direction (English → Mandarin speech): the reply flow remains
  cue-card based (`docs/REPLY-FLOW.md`).
- Translating volatile (non-final) STT text. Latency mitigation hooks are
  designed in but v1 translates finalized segments only (§7).
- Background operation (still a Swift Playgrounds app).

## 2. Research summary

Four research tracks (2026-07-14), each with confidence flags. Full source
URLs inline. Anything marked **UNVERIFIED** lands in the hardware probe
(§10) before implementation proceeds past the seam refactor.

### 2.1 Apple Translation framework

- **Headless use is now supported.** iOS 26 added
  `TranslationSession(installedSource:target:)` — a public, programmatic
  initializer that needs no SwiftUI view. The initializer itself is
  non-throwing; if the packs aren't installed, *translation calls* throw
  `TranslationError.notInstalled`, and directly-created sessions can
  never trigger downloads (`canRequestDownloads == false`). Apple's
  docs describe it exactly for "contexts where there's no UI".
  ([docs](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)))
  Confidence: high (Apple doc JSON). Field reports of the iOS 26 init in
  production: none found — real-world gotchas UNVERIFIED.
- Pre-iOS-26 the only way to get a session is the `.translationTask`
  SwiftUI modifier, with `fatalError` if the session outlives the view or
  its configuration. The min-OS decision (§4) makes this irrelevant except
  for the download flow.
- **Downloads need a visible view.** Language-pack download happens via a
  download-capable session (from `.translationTask`) + `prepareTranslation()`,
  which presents a system consent/progress sheet anchored to that view.
  Packs are system-wide (shared with the Translate app; users can also
  download in Translate → Download Languages) and translation is then
  fully on-device/offline. `LanguageAvailability.status(from:to:)` reports
  `.installed` / `.supported` (needs download) / `.unsupported`.
  Confidence: high.
- **zh-Hans ↔ en is supported** for offline packs (original WWDC24 list;
  21 languages on iOS 26). Confidence: high.
- API shape: `translate(_:)` (single string), `translations(from:)`
  (ordered batch), `translate(batch:)` (AsyncSequence). One language pair
  per session. No context/glossary/formality options. iOS 26.4 adds
  `Strategy` (`.lowLatency` vs `.highFidelity` Apple-Intelligence model) —
  worth exposing as a debug setting, default auto. Confidence: high.
- **No published latency numbers at all** for on-device translation —
  UNVERIFIED, probe measures p50/p95 per sentence.
- Swift 6 treats the view-provided session as main-actor-adjacent with
  `translate` as a `@concurrent` method (inference runs off-main). The
  isolation of directly-created sessions is undocumented — the provider
  wrapper serializes calls and never assumes parallelism (§6.2).
  Confidence: medium.
- **Works in Swift Playgrounds?** No entitlement exists for the framework
  (high confidence), but zero positive/negative reports of `import
  Translation` inside an app playground — UNVERIFIED, probe item 1.
- Not available in Simulator (physical devices only) — irrelevant here
  (Playgrounds runs on the iPad itself).

### 2.2 Apple SpeechAnalyzer / SpeechTranscriber (iOS 26)

- Architecture: `SpeechAnalyzer` (an actor) hosts modules;
  `SpeechTranscriber` is the long-form STT module. Input is an
  `AsyncStream<AnalyzerInput>` of time-coded `AVAudioPCMBuffer`s; results
  are an `AsyncSequence` of `Result { text: AttributedString, isFinal }`,
  with volatile (rapid, revisable) results opt-in via
  `.volatileResults` / the `.progressiveTranscription` preset, and
  word-level `audioTimeRange` attributes opt-in. **One analyzer analyzes
  one input sequence at a time** → one analyzer per mic lane.
  Confidence: high.
  ([docs](https://developer.apple.com/documentation/speech/speechanalyzer),
  [WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/))
- **zh_CN is a first-class locale** (42 supported locales incl. zh_CN,
  zh_TW, zh_HK, yue_CN, community-dumped from the API since beta 3;
  the CP0 probe measured 30 on the target device's build with zh_CN
  present and installed — counts vary by OS build, the on-device
  number governs).
  Match via `SpeechTranscriber.supportedLocale(equivalentTo:)`, not string
  comparison (API reports underscore forms). Confidence: high.
- Assets: downloaded programmatically via
  `AssetInventory.assetInstallationRequest(supporting:)` →
  `downloadAndInstall()` (exposes `Progress`, **no system consent sheet**),
  stored system-wide, offline afterwards. `maximumReservedLocales` is
  deliberately undocumented and device-dependent — read at runtime; we
  need only zh. Asset sizes unpublished. Confidence: high (mechanics),
  low (numbers).
- **Concurrency is the top risk.** Apple: the system "limits simultaneous
  analyses to a conservative number" and throws `insufficientResources`
  beyond it. Apple's docs name same-config sessions and interleaved audio
  schedules as cases where the *hardware* may accommodate more — but the
  sanctioned way to exceed the admission limit is the
  `ignoresResourceLimits` override, which is **iOS 27+ only**. On iOS 26,
  identically-configured transcribers "share the same backing engine
  instances and models" (real SpeechTranscriber doc text), which reduces
  memory/ANE load but may NOT raise the admission limit — so the design
  treats the analyzer pool (§6.1.1) as the primary design, not a corner
  case. Feeding only gate-passed speech keeps simultaneous *active*
  analyses rare either way.
  **MEASURED (CP0 probe, §10): the target iPad admits 3 simultaneous
  zh_CN analyses; the 4th throws `SFSpeechErrorDomain` code 16
  ("Maximum number of simultaneous requests reached") — identical
  configs did not raise the admission limit, confirming the caution
  above. Throughput ≥25× real time even at 3 concurrent lanes.**
- Streaming behavior: ~0.3–0.5 s to first volatile result (field report);
  **~1.4–2.1 s from end-of-speech to finalized text** (Apple-forum
  measurements; `prepareToAnalyze(in:)` pre-warming cuts it to ~1.45 s
  avg with high ANE-state variance). `finalize(through: CMTime)`
  force-finalizes up to a timecode *without ending the session* — the
  per-utterance flush for VAD-segmented continuous streaming. Terminating
  the input sequence does NOT finish the session; a finished analyzer
  can't accept a new sequence → keep one long-lived analyzer per lane.
  Confidence: high (API), medium (latency numbers).
- Feed the analyzer `bestAvailableAudioFormat(compatibleWith:)` — a wrong
  format fails *silently* (zero output). The model is 16 kHz mono
  internally; tapping/converting to 16 kHz directly saves ~200 ms vs
  letting it resample. Confidence: high.
- Permissions: Apple's permission doc states the `SFSpeechRecognizer`
  authorization flow "only applies to … SFSpeechRecognizer" — SpeechAnalyzer
  transcription is on-device and needs only mic permission. Several
  third-party blogs contradict this (habit carry-over). Both Microphone
  and Speech Recognition capabilities are declarable in Swift Playgrounds
  if needed. Confidence: high (doc), verify on device.
- **Chinese punctuation output (。！？) is unverified** — no published
  zh_CN sample found. English output is fully punctuated. Segmentation
  must not depend on it (§6.1) — probe item 4.
- SFSpeechRecognizer as fallback: rejected. Effectively **one concurrent
  recognition task device-wide** (forum-confirmed, both server and
  on-device), 1-minute server cap, English-only punctuation. A
  single-channel degraded mode isn't worth the code. Confidence: high.
- SpeechAnalyzer inside Swift Playgrounds: no reports either way —
  UNVERIFIED, probe item 1.

### 2.3 Apple TTS (AVSpeechSynthesizer)

- **Rendering must use `write(_:toBufferCallback:)`**, not `speak()`:
  speak() plays on the session directly with no per-lane gain, no ducking
  hook, and has been observed deactivating the app's audio session on
  completion — fatal next to live capture. write() delivers buffers we
  convert and schedule on the existing per-lane player nodes, preserving
  the ducking logic byte-for-byte. Confidence: high.
- write() contract (community-established, largely undocumented):
  callback fires repeatedly with chunks; **completion is a zero-length
  buffer** (the `didFinish` delegate is unreliable with write());
  the synthesizer must be a long-lived stored property (iOS 16 regression:
  function-local synthesizers are deallocated mid-render and the callback
  never fires); a noisy `-66686` console error is benign. Confidence: high.
- **Never trust the buffer format.** Output format varies by voice
  (22.05 kHz mono typical for compact; neural voices reported at 24 kHz;
  float32 vs int16 varies), and there was a documented era of *misreported*
  formats. Rule: sniff `buffer.format` on the first non-empty buffer per
  utterance, build an `AVAudioConverter` to the engine's 24 kHz playback
  format, sanity-check output. Confidence: high.
- **Concurrent write() across instances is publicly undocumented** —
  UNVERIFIED, probe item 3. Fallback that fully meets the requirement:
  one synthesizer per lane but a global serial *render* queue — synthesis
  is faster than real time (~151 tok/s on a 2018 iPad Pro; modern iPads
  far faster), so serializing rendering while overlapping *playback* on
  the player nodes costs only a few hundred ms of start delay on the
  rare simultaneous-speech case, which the ducking already tolerates.
  Confidence: high (fallback works), low (true parallel write()).
- Voices: `AVSpeechSynthesisVoice.speechVoices()`, filter
  `!voiceTraits.contains(.isNoveltyVoice) && !.isPersonalVoice`; quality
  tiers `.default`/`.enhanced`/`.premium` (enhanced/premium are
  user-downloaded in Settings → Accessibility → **Read & Speak** (iOS 26
  name; "Spoken Content" pre-26) → Voices — **apps cannot trigger voice
  downloads**). Identifiers are stable across OS versions but availability
  is not (deletable, purged under storage pressure, not migrated) →
  persist identifier, re-validate at start, observe
  `availableVoicesDidChangeNotification`. en-US/en-GB coverage is ample
  for 4 distinct lanes (mix gender + accent). zh voices exist (Tingting
  et al.) if a reverse lane ever appears. Personal Voice is **incompatible
  with write()** (falls back to direct output) — excluded. First use of a
  voice pays a seconds-scale rule-loading cost → pre-warm each lane's
  voice with a throwaway render at Start. Confidence: high.

### 2.4 Prior art (interface design) & future cloud providers

- Pipecat and LiveKit Agents converge on the same factoring, adopted here:
  streaming *and* request-response provider shapes behind one consumer
  surface, with **adapters** lifting request-response providers into the
  streaming shape (VAD-segmented buffering for STT; incremental sentence
  chunking for TTS). Capability flags, not type-sniffing. Transcript
  events in tiers (interim/final) with segment IDs and a `finalized`
  contract. TTS lifecycle bracket (`started/audio/stopped`) emitted by the
  orchestrator layer, not each provider. Sentence-chunking is pipeline
  policy, not a provider concern. Retry rule: retry silently only if
  nothing was emitted for the segment yet. Per-stage metrics (STT
  end-of-speech→final, MT latency, TTS time-to-first-byte) and in-band
  usage events for cost. Confidence: high (read from source).
- Future providers this design must fit without reshaping (verified
  shapes): OpenAI realtime transcription WS (append/commit with
  `turn_detection: null` — maps 1:1 onto our VAD-driven `endUtterance`),
  OpenAI `/v1/audio/speech` request-response TTS (pcm = 24 kHz s16le —
  matches our playback seam exactly), chat-completions translation
  (request-response w/ optional streaming), ElevenLabs text-streaming
  WS TTS (needs push/flush verbs — accommodated, §5.3), DeepL text API,
  and DeepL Voice (fused STT+MT — accommodated as a future fused-provider
  path, §11). Confidence: high.

## 3. Architecture overview

```
                      AppModel (unchanged responsibilities)
   EngineGraph tap → audioQueue → ChannelGate → per-lane LaneEngine
                                                      │
                            ┌─────────────────────────┴───────────────┐
                            │ RealtimeLaneEngine                      │ CascadeLaneEngine
                            │  (adapter around                        │  (new)
                            │   RealtimeTranslationClient,            │
                            │   zero behavior change)                 │
                            └────────────┬────────────────────────────┤
                                         │                            │  STTStream (Apple SpeechTranscriber)
                    onTranscript ────────┤                            │    ↓ finalized segments
                    onTranslatedAudio ───┤                            │  Translator (Apple TranslationSession)
                    onCostDelta ─────────┤                            │    ↓ translated text
                    onMetric ────────────┘                            │  SpeechSynth (AVSpeechSynthesizer.write,
                                                                      │    per-lane voice) → 24k PCM16
                             AppModel.playEnglishAudio → EngineGraph lane player (ducking unchanged)
                             TranscriptStore (delta path + new replace path)
```

The seam is a `LaneEngine` protocol at exactly the point where AppModel
today talks to `RealtimeTranslationClient`. Everything above the seam
(gate, meters, lazy open, idle close, watchdog, route handling) and below
it (player nodes, ducking, transcript UI) is reused by both pipelines.

Cross-lane pieces owned by a new `CascadeContext` (created per
conversation when the cascade is selected): the shared
`TranslationSession` (one per language pair, lanes share it), the
**AnalyzerPool** (§6.1.1), and — retained as a contingency only, since
the probe showed 2-wide `write()` renders overlap (§10) but 3–4-wide is
unverified — a shared TTS render queue.

## 4. Minimum OS: iOS 26

`Package.swift` moves `.iOS("18.0")` → `.iOS("26.0")`. Justification:
Swift Playgrounds 4.7 (required to build this app) already requires
iPadOS 26 on the only device class that runs it; SpeechAnalyzer and the
headless `TranslationSession` initializer are both iOS 26+. This removes
all `#available` gymnastics and the entire iOS 18 hidden-host-view
translation hack from scope. The realtime pipeline is unaffected.

## 5. The provider seam

Three small protocol families plus the lane-engine seam. Conventions match
the existing codebase: classes + callbacks delivered on a private serial
queue (consumers hop to main), `snapshot()` for diagnostics, `Log` for
evidence. Swift-concurrency APIs (SpeechAnalyzer, TranslationSession) are
bridged *inside* provider implementations; the seam stays callback-based
so AppModel's dispatch-queue pipeline doesn't grow a second threading
model at the boundary.

### 5.1 LaneEngine — the seam AppModel sees

```swift
enum LaneEngineState: Equatable {
    case idle
    case starting                       // connecting / warming up
    case running
    case degraded(String)               // running but impaired (e.g. STT pool contention)
    case reconnecting(attempt: Int)     // realtime: closed, backoff timer armed
    case failed(String)
}

/// Per-buffer gate outcome carried across the seam.
struct GateVerdict {
    /// Hangover-smoothed "this lane is speaking" — today's `speech`
    /// conjunction (pass && voiced). Opens lanes lazily, feeds the
    /// realtime first-response clock, defeats idle-close.
    let speech: Bool
    /// Instantaneous genuine voicing for THIS buffer — the raw VAD
    /// verdict minus bleed, before the hangover is applied. The cascade
    /// closes utterances on a short debounce of this flag (§6.1) so the
    /// worn profile's 1.5 s hangover is NOT added to cascade latency;
    /// the hangover tail still flows to STT as trailing context because
    /// `pass` stays true through it.
    ///
    /// The bleed subtraction is load-bearing, not a nicety: the raw VAD
    /// fires on bleed too (bleed IS speech), so a close debounce keyed
    /// on VAD-voicing alone would be starved on a suppressed lane for as
    /// long as the louder correlated speaker keeps talking — systematic
    /// in the ambient chest+hand setup, where the losing mic is
    /// voiced-but-bleed for entire turns. Genuine voicing goes false the
    /// moment a lane loses its pair, so the debounce closes on schedule.
    ///
    /// Requires a small gate change, stated here so CP1 doesn't discover
    /// it: ChannelGate already computes this internally
    /// (`genuine = voicedNow[i] && !bleed[i]`, ChannelGate.evaluate
    /// step 3) but exposes only the hangover-smoothed `voiced` —
    /// Decision gains a field carrying the existing `genuine` value, and
    /// ChannelTelemetry gains the same field so the Signal tab can plot
    /// the flag the cascade actually segments on. No gate behavior
    /// changes.
    let voicedNow: Bool
    /// Gate pass (bleed-suppressed ⇒ false). Realtime substitutes
    /// silence when false; cascade sends nothing.
    let pass: Bool
}

/// One notice channel per lane so engines own their banner lifecycles
/// (raise AND retract) without clobbering unrelated errors: AppModel
/// clears a displayed banner only when the clearing id matches the one
/// that raised it — the same text-equality discipline reconnectBanner
/// implements today, made explicit.
enum LaneNotice {
    case raised(id: String, text: String)
    case cleared(id: String)
}

/// Everything between "gated audio for one lane" and "transcript +
/// translated audio out". One instance per lane per conversation.
protocol LaneEngine: AnyObject {
    var label: String { get }

    /// Called on audioQueue for EVERY tap buffer (hardware-rate mono
    /// float32) with the gate's verdicts. The engine decides what to do
    /// with it (silence substitution vs. drop) — and the engine owns its
    /// converters: it MUST compare `buffer.format` against its
    /// converter's input format on every call and rebuild on change.
    /// Route churn (USB replug, BT codec renegotiation) changes the
    /// hardware rate mid-conversation; today AppModel rebuilds the
    /// resamplers on route change, and that responsibility moves inside
    /// the seam — a stale converter in the STT path fails SILENTLY
    /// (research §2.2), so this is a correctness rule, not an
    /// optimization.
    func sendAudio(_ buffer: AVAudioPCMBuffer, verdict: GateVerdict)

    func start()
    func close()

    // Callbacks on the engine's private queue; consumers hop to main.
    var onState: ((LaneEngineState) -> Void)? { get set }
    var onNotice: ((LaneNotice) -> Void)? { get set }
    var onTranscript: ((TranscriptEvent) -> Void)? { get set }
    /// 24 kHz mono PCM16 LE — the existing playback seam.
    var onTranslatedAudio: ((Data) -> Void)? { get set }
    /// Monotonic dollar increments (realtime: billed seconds × the
    /// per-minute rate, which moves from CostMeter into the adapter;
    /// Apple cascade: never fires). Deliberately NOT identity-guarded by
    /// AppModel — an engine evicted at idle-close keeps this callback
    /// alive through its close drain so drained audio still bills,
    /// exactly like onBilledSeconds today.
    var onCostDelta: ((Double) -> Void)? { get set }
    var onMetric: ((LaneMetric) -> Void)? { get set }

    func snapshot() -> LaneEngineSnapshot
}

enum TranscriptEvent {
    // Realtime path: append-only deltas, segmentation by quiet timeout
    // (exactly today's TranscriptStore behavior).
    case sourceDelta(String)
    case translationDelta(String)
    // Cascade path: replace-in-place keyed by utterance, explicit
    // finalization (volatile STT text is revised wholesale).
    case sourceText(utterance: UUID, text: String, isFinal: Bool)
    case translationText(utterance: UUID, text: String, isFinal: Bool)
}

enum LaneMetric {
    case connectSeconds(Double)          // realtime
    case firstResponseSeconds(Double)    // realtime (existing meaning)
    case sttFinalizeSeconds(Double)      // cascade: speech-end → final text
    case translationSeconds(Double)      // cascade: final text → translation
    case ttsFirstAudioSeconds(Double)    // cascade: translation → first PCM
    case endToEndSeconds(Double)         // cascade: speech-end → first PCM
}

enum LaneEngineSnapshot {
    case realtime(RealtimeTranslationClient.Snapshot)
    case cascade(CascadeSnapshot)        // §9
}
```

`RealtimeLaneEngine` is a thin adapter: it owns a
`RealtimeTranslationClient` + the lane's `StreamResampler`, forwards
deltas/audio/billing, and absorbs the reconnect loop AppModel runs today.
`sendAudio` keeps the exact current semantics: gate-suppressed buffers
become silence, everything is resampled to 24 kHz PCM16 and appended.

AppModel changes are mechanical: `clients: [Int: RealtimeTranslationClient]`
becomes `engines: [Int: any LaneEngine]`; `sessionStates` becomes
`[Int: LaneEngineState]` (dot mapping: idle→gray, starting/reconnecting→
yellow, running→green, degraded→orange, failed→red). One guard-parity
detail: today AppModel suppresses same-value `sessionStates` publishes,
and `.reconnecting(attempt: 3) != .reconnecting(attempt: 4)` would
defeat that on every retry — the publish guard compares **case
identity**, not full equality, so the dot's publish cadence stays
exactly today's (the attempt count still reaches Diagnostics via
`snapshot()`). `makeClient` becomes
a factory switching on the pipeline setting; `wireClient` wires the new
callbacks. **Lifecycle is pipeline-dependent**: lazy-open-on-speech and
idle-close remain exactly as today for realtime engines (they bound
billing); cascade engines open eagerly at Start and are exempt from
idle-close (§6.1 — closing an analyzer is terminal and re-opening re-pays
seconds of warm-up on the first utterance after every lull, for zero
saved cost). Disabled-mic close applies to both kinds; re-enabling builds
a fresh engine.

#### 5.1.1 CP1 acceptance: the realtime contract, itemized

CP1's "zero behavior change" claim is only testable if the observable
contract is written down. Moving the reconnect machinery into
`RealtimeLaneEngine` must preserve ALL of the following, verbatim from
today's AppModel behavior:

1. **Indefinite retry, capped backoff**: reconnect attempts continue for
   as long as the conversation runs, delay `min(30, 2^min(attempts,5))` s.
   The retry chain is bounded only by `close()` (Stop, idle-close,
   disabled-mic): a pending backoff timer inside a closed engine must
   no-op, mirroring today's "client still registered" guard at timer
   fire.
2. **Survival-gated counter reset**: the attempt counter resets only
   after a connection survives ≥ 5 s in `.open` (`sessionOpenedAt`
   discipline) — an open-then-instant-reject loop must not retry with a
   fresh counter forever.
3. **Attempt-5 banner**: on the 5th consecutive attempt, raise
   `LaneNotice.raised(id: "reconnect.<lane>", text:)` with today's
   "keeps failing — still retrying every 30 s" wording; AppModel maps it
   to `errorBanner`.
4. **Self-clearing recovery**: after 5 s of surviving `.open`, the engine
   emits `cleared(id: "reconnect.<lane>")`; AppModel clears `errorBanner`
   only if the currently displayed banner was raised under that id —
   an unrelated error that replaced it meanwhile must survive (today's
   text-equality check, keyed by id instead).
5. **Billing through the drain**: `onCostDelta` is not identity-guarded;
   an idle-closed engine's close drain keeps billing (existing
   `onBilledSeconds` comment contract).
6. **Lazy open + pre-open queue**: first-speech open with the client's
   ~30 s pre-open audio queue and flush-on-open ordering, untouched
   (stays inside `RealtimeTranslationClient`).
7. **Pipeline statuses**: `snapshot()` returns the same
   `RealtimeTranslationClient.Snapshot` (wrapped), sampled at 1 Hz, so
   the Diagnostics panel renders identically.

Acceptance test: a realtime conversation with induced network loss
(airplane-mode toggles at various phases) is indistinguishable from
today's build — same dots, same banners, same recovery, same cost.

### 5.2 Stage providers

```swift
enum ProviderAvailability {
    case ready
    case needsDownload(action: DownloadAction)   // .inApp(progressable) | .systemSettings(path: String)
    case unsupported(reason: String)
}

// ---- STT ----------------------------------------------------------------
protocol STTProviderFactory {
    var id: String { get }                       // "apple", "openai", …
    func availability(locale: Locale) async -> ProviderAvailability
    /// One stream per lane. Identical configs across lanes (required for
    /// Apple engine sharing; harmless elsewhere).
    func makeStream(locale: Locale) throws -> any STTStream
}

protocol STTStream: AnyObject {
    /// The format send() expects; the lane engine owns the converter.
    var inputFormat: AVAudioFormat { get }
    func send(_ buffer: AVAudioPCMBuffer)        // speech-bearing audio only
    /// VAD said the utterance ended: force-finalize what's buffered.
    /// Apple: finalize(through: lastAudioTime). OpenAI: buffer.commit.
    func endUtterance()
    func finish()
    var onResult: ((STTResult) -> Void)? { get set }
    var onError: ((STTError) -> Void)? { get set }   // .recoverable / .fatal
}

struct STTResult {
    let utteranceID: UUID       // stream-assigned; stable volatile→final
    let text: String            // full replacement text for the utterance
    let isFinal: Bool
}

// ---- Translation --------------------------------------------------------
protocol TranslationProviderFactory {
    var id: String { get }
    func availability(from: Locale.Language, to: Locale.Language) async -> ProviderAvailability
    /// Cardinality is PROVIDER-DEFINED: Apple shares one translator per
    /// language pair per conversation (62 ms, serialized is fine);
    /// OpenAI creates one per lane (0.5–1.5 s/request — lanes must
    /// translate in parallel). CascadeContext/engine typing moves to
    /// `any Translator` when the first non-Apple provider lands (§14).
    func makeTranslator(from: Locale.Language, to: Locale.Language) async throws -> any Translator
}

protocol Translator: AnyObject {
    /// Serialized internally; callers may invoke from any queue. `job`
    /// correlates streaming deltas with the awaited result — streaming
    /// providers deliver ACCUMULATED text via onDelta(job, textSoFar)
    /// before resolving. `context` is the pushed cross-lane window
    /// (§14.1); on-device providers ignore it. Each job resolves EXACTLY
    /// once; TranslationResult.viaFallback marks a cloud job served by
    /// its on-device fallback (excluded from the context window, counted
    /// in Diagnostics).
    func translate(_ text: String, context: [TranslationContextPair], job: UUID) async throws -> TranslationResult
    var onDelta: ((UUID, String) -> Void)? { get set }   // optional streaming hook
    var onCostDelta: ((Double) -> Void)? { get set }     // cloud token cost; Apple never fires
    func cancelAll()
}

// ---- TTS ----------------------------------------------------------------
struct TTSVoice: Identifiable, Equatable {
    let id: String              // provider-scoped identifier
    let name: String
    let language: String        // BCP-47
    let quality: String         // "premium" / "enhanced" / "default" / provider tier
}

protocol TTSProviderFactory {
    var id: String { get }
    /// Installed & usable voices for a target language, best first,
    /// novelty/personal filtered. Re-queried on availableVoicesDidChange.
    func voices(for language: Locale.Language) -> [TTSVoice]
    /// Human instructions for getting more voices (nil if N/A).
    var voiceDownloadHint: String? { get }
    func makeSynth(voice: TTSVoice.ID) throws -> any SpeechSynth
}

protocol SpeechSynth: AnyObject {
    /// Audio arrives as 24 kHz mono PCM16 chunks (providers convert
    /// internally), bracketed by onFinished per job. The synth has NO
    /// internal queue contract and NO per-job cancel: the lane engine
    /// owns the pending queue and submits at most ONE job at a time
    /// (submit next on onFinished) — backpressure drops (§7) happen in
    /// the engine's queue before submission, and cancelAll is only for
    /// Stop/close.
    func synthesize(text: String, job: UUID)
    func cancelAll()
    var onAudio: ((UUID, Data) -> Void)? { get set }
    var onFinished: ((UUID, _ error: String?) -> Void)? { get set }
}
```

Deliberate simplifications vs Pipecat/LiveKit, and why they're safe:

- **No interim-transcript capability flag**: `STTResult.isFinal` carries
  the tier; a provider that never emits volatile results just never sends
  `isFinal == false`. The transcript replace-path renders both.
- **Translator is request-response with an optional streaming hook**, not
  an AsyncSequence: Apple and DeepL are single-shot; OpenAI chat streaming
  fits `onDelta` (UI preview) while the returned value stays the unit that
  feeds TTS. Sentence-chunking streamed MT into TTS early is a future
  optimization confined to CascadeLaneEngine (§7) — the seam already
  carries what it needs.
- **SpeechSynth takes whole sentences** (no push/flush text streaming):
  Apple's synthesizer requires full utterance text up front anyway. An
  ElevenLabs WS provider wraps its push/flush protocol behind
  `synthesize(text:job:)` per sentence — its multi-context socket maps to
  one synth per lane. If token-streaming TTS ever matters, a
  `StreamingSpeechSynth` refinement can be added without touching this
  seam (LiveKit's dual-shape precedent).
- **Retry policy** lives in providers, following the researched rule:
  retry internally only if nothing was emitted for the current
  segment/job; after partial emission, surface `onError`/`onFinished(error:)`
  and let the lane engine decide (§8).

### 5.3 Why this seam survives the future providers

| Future provider | Fits as |
| --- | --- |
| OpenAI realtime transcription (WS, append/commit, `turn_detection: null`) | `STTStream`: `send` = append, `endUtterance` = commit, deltas → volatile results, `completed` → final |
| OpenAI `/v1/audio/speech` (pcm 24 kHz s16le, chunked response) | `SpeechSynth`: one HTTPS request per job, chunks → `onAudio` unmodified |
| OpenAI chat-completions MT | `Translator` with `onDelta` streaming |
| ElevenLabs stream-input WS | `SpeechSynth` per lane; init message on makeSynth, sentence + `flush:true` per job, `isFinal` → onFinished; PCM 24k output mode |
| DeepL text API | `Translator` (single-shot, `context` param fed from lane history if we ever add it) |
| DeepL Voice (fused STT+MT) | Future `FusedSTTTranslationProvider` consumed by CascadeLaneEngine in place of the STT+MT pair — the engine already treats "final source text" and "translated text" as separate events keyed by utterance, which is exactly what a fused stream emits (§11) |

## 6. The Apple providers

### 6.1 AppleSTTProvider (SpeechAnalyzer + SpeechTranscriber)

Analyzers are owned by a shared **AnalyzerPool** (in `CascadeContext`),
not by lanes — the CP0 probe measured an admission limit of **3
simultaneous analyses** on the target iPad (§10), one short of the 4
lanes, so pooling is the primary design, with lane-static binding as its
natural degenerate case when the pool is big enough. Each pool slot is
one long-lived `SpeechAnalyzer` in autonomous mode
(`start(inputSequence:)`) with one `SpeechTranscriber` configured
identically across slots (locale from the source-language setting via
`supportedLocale(equivalentTo:)`, preset `.progressiveTranscription`
(volatile + fast), no `audioTimeRange` in v1). The pool design is
§6.1.1.

- **Input**: the lane engine converts gate-passed buffers to
  `bestAvailableAudioFormat(compatibleWith: [transcriber])` (queried at
  start; expected 16 kHz mono) with a dedicated `AVAudioConverter`,
  rebuilt whenever the incoming `buffer.format` changes (§5.1 rule —
  route churn changes the hardware rate, and a stale converter here
  fails *silently*; the probe measured the analyzer format as 16 kHz
  mono int16). Converted buffers are wrapped in `AnalyzerInput` and
  yielded into the **acquired slot's** continuation while the lane holds
  one; between acquisitions — waiting under contention, or the
  post-release hangover tail — they land in the lane-side buffer
  (§6.1.1) and burst-feed on the next acquisition. Non-speech buffers
  are *not* sent (unlike realtime's silence-substitution), so slots only
  advance during speech and idle lanes cost nothing.
- **Segmentation** (this is where cascade latency is won or lost): an
  utterance opens on the first `pass && voicedNow` buffer after quiet.
  The close trigger is a **debounce of `voicedNow` going false** — the
  genuine pre-hangover flag (§5.1), NOT the hangover-smoothed `speech`
  flag. The hangover (1.5 s worn / 2.0 s ambient) exists to keep the
  *gate* open across word gaps and MUST NOT sit in the cascade's
  response path; audio keeps flowing through the hangover tail (`pass`
  stays true) — into the held slot until close, and into the lane-side
  buffer after release (§6.1.1) — so if the debounce fires early and
  the speaker resumes, the trailing audio was captured (analyzed at the
  next acquisition as leading context) and the next utterance opens
  cleanly. The quality trade-off is acknowledged, not free:
  a spurious close still splits one thought into two context-free MT
  calls and two TTS jobs (Apple MT takes no context), so the debounce
  is **two-tier**, reusing the codebase's `finalizeSentenceTimeout`
  precedent: **400 ms when the accumulated volatile text already ends
  in a sentence ender, 750 ms otherwise** (mid-sentence hesitations
  routinely exceed 400 ms). Both constants are probe-tuned (item 6
  measures exactly this). On close: `endUtterance()` → finalize through
  **everything fed to the slot so far** (the full cursor — deliberately
  NOT `lastSpeechTime`): the segment's final result is forced without
  ending the session, and no un-finalized volatile region ever remains
  on a slot at release — the precondition that makes §6.1.1's
  one-owner-at-a-time result demux safe. The few hundred ms of
  already-fed tail audio inside the finalized range is trailing
  near-silence; the rest of the tail arrives post-release and buffers
  lane-side.
  Two forced-split rules bound utterance length independent of the VAD:
  1. **Punctuation sub-segmentation** (accelerator): when a *final*
     result arrives mid-utterance ending in sentence punctuation
     (。！？.!?), the accumulated sentence(s) release downstream early.
     zh punctuation is UNVERIFIED (probe item 4) — nothing depends on it.
  2. **Max-duration split** (hard bound): at 12 s of continuous
     utterance, a finalize through everything fed so far (the same
     full-cursor rule as a normal close) fires and a new utterance UUID
     continues seamlessly. Without this, ambient mode (2.0 s hangover,
     12 s sustained-voice timeout, continuous surrounding chatter) can
     hold one utterance open for minutes, starving MT and TTS until the
     room quiets and then dumping one giant segment. The bound
     guarantees translation flows during continuous speech even if
     punctuation never appears.
- **Results**: volatile results replace the utterance's source text live
  (`.sourceText(utterance:text:isFinal:false)`) — Chinese appears on
  screen *while the person talks*, which the realtime pipeline never did.
  The final result replaces it once more and feeds translation.
- **Lifecycle**: the pool and the per-lane engines open **eagerly at
  Start** and stay open until Stop — exempt from idle-close. Rationale:
  finishing an analyzer is terminal (it cannot accept a new input
  sequence), so idle-closing after the default 120 s lull would re-pay
  slot creation + `prepareToAnalyze` + possibly voice rule-loading on
  the *first utterance after every quiet spell* — the exact moment users
  judge latency — to save nothing (no billing, and an idle slot
  receiving no audio costs ~nothing). Eager open also front-loads the
  admission-limit discovery: the pool learns N *deterministically at
  Start* instead of surprising the user mid-conversation when a fourth
  speaker finally talks. **Re-enable mid-conversation**: a cascade
  engine for a re-enabled mic is built lazily on that lane's next
  `sendAudio` (the per-buffer enabled-mask read already notices the
  transition); the pool itself is unaffected — lanes are lightweight
  (converter + synth + segmentation state), the analyzers live in the
  pool.
- **Warm-up**: pool slots are pre-warmed at Start (§6.1.1). Measured
  effect (§10): finalize p50 0.08 s → 0.03 s.
- **Assets**: `AssetInventory` request at setup time with `Progress`
  surfaced in the setup card (§8.1); `.assetUnavailable` at Start →
  banner pointing at the card.
#### 6.1.1 The AnalyzerPool (pooled-mode design pass, gate satisfied)

> **FIELD REVISION (2026-07-15)** — implemented and shipped, supersedes
> the long-lived-slot model below: `finalize(through:)`, this section's
> core mechanism, **hangs indefinitely on live streams on-device** in
> every form tried (cursor-targeted and nil), per three instrumented
> field runs. Slots are therefore **per-utterance**: close = silence pad
> + `finalizeAndFinishThroughEndOfInput` (the probe-proven path, flushes
> finals in ~0.1 s, bounded) → retire (references dropped so the
> analyzer frees its admission share) → pre-warmed replacement with
> backoff, plus a slow perpetual recovery loop if the pool ever fully
> dies. Every analyzer await is wall-clock-bounded so a hung OS call can
> never wedge a lane. Results are epoch-stamped against straggler
> misattribution. The FIFO acquisition, one-owner demux, lane-buffer,
> and contention behavior below remain as designed. Authoritative
> details: `Cascade/AnalyzerPool.swift` header +
> `Cascade/CascadeLaneEngine.swift`.

The probe admitted 3 of 4 lanes, so this section is the design pass the
phasing gate required. The measured throughput makes pooling cheap:
transcription ran ≥25× real time (10.8 s of audio in ~0.3–0.4 s, even
with 3 concurrent lanes), so a lane that waits for a slot and then
burst-feeds its buffered audio typically catches up in well under a
second (~1.5 s at the 30 s buffer bound — see the contention bullet).

- **Discovery at Start**: create-and-start identical zh slots one at a
  time up to `min(enabledLanes, 4)`, catching the admission error. The
  probe observed `SFSpeechErrorDomain` code 16 ("Maximum number of
  simultaneous requests reached"); Apple publishes no raw values for
  `SFSpeechError.Code`, so equating code 16 with the documented
  `insufficientResources` case is unconfirmed — discovery therefore
  matches on the error DOMAIN and logs the code, depending on neither
  name. The count that succeeds is the pool size N (measured: 3). This
  keeps Start-time behavior deterministic and turns "how many does this
  device allow" into a runtime measurement instead of a constant.
- **Slots**: long-lived for the conversation, pre-warmed with
  `prepareToAnalyze(in:)`, each with its own input continuation, its own
  results-harvest task, and a running **time cursor** (`CMTime`) that
  advances by each fed buffer's duration. A slot serves ONE lane at a
  time, so result demux is trivial: the harvest task forwards volatile
  and final results to the slot's current owner.
- **Acquisition**: a lane acquires a slot at utterance open (first
  `pass && voicedNow` buffer) and releases it after `endUtterance()` →
  `finalize(through: cursor)` delivers the final result — where the
  cursor is the FULL fed timeline (§6.1's close rule), so release never
  leaves an un-finalized volatile region on the slot; that invariant is
  what makes one-owner demux safe across owner switches. The utterance
  occupies a contiguous range on the slot's timeline; the cursor carries
  across acquisitions (finalize-through does not end the session).
  Acquisition is FIFO by utterance start.
- **Contention** (all N slots busy — a 4th simultaneous speaker): the
  lane buffers its converted audio (bounded at ~30 s, the realtime
  pre-open queue's bound) and burst-feeds on acquisition. Typical
  contention is brief — a slot frees whenever any in-flight utterance
  finalizes (~0.1 s measured), so waits are bounded by the remaining
  length of someone else's utterance and backlogs are seconds of audio
  clearing in well under a second at the measured ≥25× rate. Worst case
  (full 30 s buffer): ~1.2–1.5 s of catch-up — and that rate is one
  device on clean looped audio, so Diagnostics counts every wait and
  its duration rather than trusting the number. The lane reports
  `.degraded("waiting for a speech model — simultaneous speech may
  lag")` only if the wait itself exceeds 2 s.
- **N ≥ enabled lanes** (fewer mics, or a future OS raising the limit):
  the same code path simply never contends — no separate "direct"
  mode.
- **Slot death**: recreate once (fresh analyzer, cursor reset, owner
  re-acquires); on repeated failure the pool shrinks by one and logs.
- **Interaction with the 12 s hard split**: a split releases and
  immediately re-acquires the same slot (FIFO grants it to the waiting
  continuation utterance unless another lane was already queued —
  fairness over stickiness).

### 6.2 AppleTranslationProvider (Translation framework)

One `TranslationSession(installedSource:target:)` per language pair per
conversation, shared by all lanes (`CascadeContext`), created inside a
dedicated `Task` at conversation start after an availability check.

- **Serialization**: all `translate(_:)` calls funnel through one
  in-order queue (an `AsyncStream` of jobs consumed by a single task).
  Research found no documented concurrent-call support; measured
  single-sentence latency is expected to be small (probe item 5 puts
  numbers on it). If p95 across 4 chatty lanes ever matters, batching
  via `translations(from:)` per tick is the escape hatch — the seam
  doesn't change.
- **Isolation hedge**: the session lives inside its own actor; if the
  directly-created session turns out main-actor-bound (undocumented),
  only that actor's internals change to hop.
- **Errors**: `.notInstalled` mid-conversation (user deleted the pack) →
  fatal for the stage → lane engines surface `failed("Translation pack
  removed — reinstall in setup")`; conversation keeps transcribing with
  translation marked missing rather than tearing down capture.
- **Downloads**: the *setup card* (§8.1) hosts the one place a
  download-capable session exists: a real SwiftUI view with
  `.translationTask(configuration)` + `prepareTranslation()`, showing the
  system sheet. Steady state never touches SwiftUI.
- v1 sends segments as-is, no context stitching (the API takes none).

### 6.3 AppleTTSProvider (AVSpeechSynthesizer.write)

One long-lived `AVSpeechSynthesizer` per lane (stored for the
conversation's duration — the iOS 16 deallocation bug makes function-local
synthesizers silently dead), each bound to the lane's configured voice.

- **Render path**: `write(_:toBufferCallback:)` per job → skip empty
  sentinel → on first real buffer, read the *actual* format and build an
  `AVAudioConverter` to 24 kHz mono; convert each chunk; emit PCM16 Data
  via `onAudio` → the lane engine forwards to `onTranslatedAudio` → the
  existing `playEnglishAudio` schedules it on the lane's player node with
  ducking untouched. Zero-length buffer → `onFinished`. (Yes, this is a
  wasteful voice-native-float → PCM16 → float32 round trip; it is the
  price of keeping the playback seam, ducking, and future cloud-TTS
  providers — which genuinely emit 24 kHz PCM16 — on one code path.
  Fractions of a millisecond per chunk; not worth a second seam.)
- **Concurrency**: per-lane synths give per-lane FIFO for free. Whether
  two `write()` renders run truly concurrently is probe item 3; if not
  (or if glitchy), all synths share one serial render queue owned by
  `CascadeContext` — playback still overlaps because rendering is
  faster than real time; the later lane just starts ~0.2–0.5 s later,
  within what ducking already handles.
- **Warm-up**: at Start, render one short throwaway utterance per
  distinct configured voice (absorbs the seconds-scale voice-load cost
  off the critical path).
- **Rate/pitch**: per-lane rate defaults to
  `AVSpeechUtteranceDefaultSpeechRate`; a global "speech rate" slider in
  Settings applies to all lanes (translated speech racing a live
  conversation benefits from ~1.1×).
- Session mode stays `.default` (the `.spokenAudio` accessibility-graph
  degradation from research; our session config doesn't use it today —
  keep it that way).

### 6.4 Per-lane voice configuration

- **Storage**: `AppSettings.laneVoice(provider:language:channel:)` →
  `"laneVoice.\(provider).\(language).\(channel)"` (UserDefaults, same
  pattern as speaker names). The **target language is part of the key**:
  `outputLanguage` already supports more than English, and an en-US voice
  identifier validates fine while happily mispronouncing French — keying
  by language means switching the output language switches to that
  language's voice assignments (auto-assigned on first use) instead of
  reusing the wrong ones.
- **Defaults**: on first use (or when a stored voice fails validation),
  auto-assign distinct voices: enumerate `voices(for: outputLanguage)`,
  rank **premium > enhanced > super-compact > compact > everything
  else**, interleave gender/accent variety (en-US/en-GB mix), assign
  index-wise per channel, then persist so the assignment is stable ever
  after. The bottom tier exists because the probe's inventory (§10)
  showed a fresh device is dominated by voices that pass the
  novelty/personal filter but should never be auto-assigned: the
  `com.apple.eloquence.*` set (Eddy/Flo/Grandma/Grandpa/…) and the
  legacy MacinTalk voices (`com.apple.speech.synthesis.voice.*` — Fred,
  Kathy, …). They stay selectable in the picker (grouped last), just
  never chosen automatically. On a stock device the auto-assignment
  therefore lands on Samantha/Daniel/Karen/Moira-class voices, and the
  Settings hint to download enhanced/premium voices is what unlocks
  genuinely distinct, pleasant lanes. **Fewer usable voices than enabled
  lanes** (thin non-English inventories; a fresh device): cycle the
  ranked list so duplicates land on the least-adjacent channels, log it,
  and show a "2 lanes share this voice — download more voices" note on
  the affected Settings rows. Distinct-by-default is best-effort, never
  a blocker.
- **Validation**: at Start, `AVSpeechSynthesisVoice(identifier:)` nil OR
  `voice.language` not matching the target language → log, banner-note,
  auto-reassign (voices are deletable/purgeable).
  Observe `availableVoicesDidChangeNotification` to refresh Settings live.
- **UI**: each speaker row in Settings gains a voice menu (name +
  quality badge) and a ▶ preview that renders a sample sentence through
  the real write()→engine path (also doubles as a smoke test). A footer
  links the "download better voices in Settings → Accessibility → Read &
  Speak → Voices" instruction (`voiceDownloadHint`).
- The same UI serves future TTS providers: the menu lists
  `voices(for:)` of whichever provider is selected for the TTS stage,
  and the per-provider storage key keeps each provider's choice.

## 7. CascadeLaneEngine orchestration

Per lane, one serial dispatch queue (`translator.cascade.laneN`) confines
all state, mirroring `RealtimeTranslationClient`'s discipline. Stages
communicate through it; Swift-concurrency provider APIs are bridged with
`Task { … }` whose completions hop back onto the lane queue.

**Utterance state machine** (per utterance UUID):

```
capturing ──endUtterance──▶ finalizing ──final text──▶ translating
    │ volatile text                                        │
    ▼                                                      ▼
 transcript (replace, live)                          transcript (translation)
                                                           │
                                                     synthesizing ──▶ speaking ──▶ done
```

- Ordering: per-lane FIFO end-to-end. Utterance N+1 may *transcribe*
  while N translates/speaks (stages pipeline), but translations are
  submitted in order and TTS jobs are enqueued in order, so spoken output
  never reorders within a lane.
- **Backpressure**: if a lane's unspoken backlog exceeds 3 utterances
  (a burst of rapid short turns while TTS is busy), the oldest unspoken
  job is dropped *from audio only* — its translation stays on screen,
  a `Log.warn` and a Diagnostics counter record the skip. Rationale:
  at a live table, stale speech is worse than a visible transcript.
- **Cancellation**: a LANE close (disabled mic — cascade lanes are
  idle-close-exempt) finalizes through the fed cursor, releases its
  slot, drops its lane buffer, and cancels its own MT/TTS jobs — it
  must NEVER finish a slot: slots are shared, and finishing is terminal
  (a mic toggle would shrink the pool for the rest of the
  conversation). Only `CascadeContext` teardown at Stop finishes slots:
  `finalizeAndFinishThroughEndOfInput()` per slot with a 3 s drain cap
  (mirrors the realtime close drain), then `Translator.cancelAll()`,
  `SpeechSynth.cancelAll()`, state `.idle`. In-flight utterances
  finalize into the transcript if the drain returns them in time.
- **Latency budget** — pre-probe expectations vs CP0 measurements
  (probe, 2026-07-14, clean paced TTS audio; live far-field mic speech
  may run slower, so the expected column keeps its margin):

| Stage | Expected (pre-probe) | Measured (CP0) |
| --- | --- | --- |
| Live Chinese on screen (volatile) | 0.3–0.5 s behind speech | not separately timed |
| Utterance boundary detection (two-tier `voicedNow` debounce, §6.1) | 0.4 s (sentence-ended) – 0.75 s | by construction |
| Boundary → final Chinese (`finalize(through:)`) | ~1.0–2.0 s (field reports) | **p50 0.08 s; 0.03–0.05 s with `prepareToAnalyze`** |
| Final → translation (Apple, on-device) | ≤ 0.3 s assumed | **p50 62 ms, p95 210 ms (cold 210 ms); batch 59 ms/sentence** |
| Translation → first translated audio (warm voice) | ~0.1–0.5 s | overlapping renders confirmed; per-utterance TTFB not separately timed |
| **Speech-end → translated audio** | ~1.8–3.5 s | **~0.7–1.6 s projected** (debounce-dominated) |

  The measured finalize latency is ~20× better than the public field
  reports (clean audio, short utterances, warm shared engine — but even
  a 5× degradation on live mics leaves the total under ~2 s). The
  budget is now dominated by the boundary debounce itself, which is
  deliberate margin, not model time. Had the boundary been derived from
  the hangover-smoothed `speech` flag, the worn profile's 1.5 s
  (ambient: 2.0 s) hangover would sit at the head of this chain — that
  is why `GateVerdict` carries `voicedNow` (§5.1). The cascade still
  trades interpreter-style overlap (realtime translates mid-speech; the
  cascade answers after the utterance) for: source text *ahead* of the
  realtime pipeline (volatile results beat the whisper stream's lag),
  offline operation, $0, and voice-per-speaker. Mitigations if live
  latency disappoints, in order: translate on the volatile text at the
  VAD boundary and reconcile (research: ~95% match on short
  utterances), tighter debounce, `.lowLatency` strategy pinning (26.4).
  Sentence sub-segmentation and the 12 s hard split are already v1
  (§6.1).

### 7.1 Transcript integration (TranscriptStore changes)

TranscriptStore today is built around one invariant the cascade breaks:
**at most one open utterance per lane** (`openUtteranceIndex`), advanced
by append-only deltas and closed by quiet-timeout (`finalizeStale`) with
`reopenRecentIfNeeded` patching up late deltas. The cascade pipelines
utterances — N's translation lands *after* N+1's bubble opened — and
finalizes explicitly. The store changes:

- **Identity**: cascade events are UUID-keyed. The store gains
  `openCascade: [UUID: Int]` (utterance UUID → array index, shifted by
  `trim()` exactly like `openUtteranceIndex`), allowing multiple open
  bubbles per lane. Bubbles append in utterance-open order; a bubble's
  translation fills in place when it arrives (visually identical to
  today's late whisper bursts filling finalized bubbles).
- **Provenance**: `Utterance` gains
  `segmentation: .quietTimeout | .explicit`. `finalizeStale`,
  `reopenRecentIfNeeded`, and the sentence-timeout fast path apply ONLY
  to `.quietTimeout` (realtime) utterances — they'd otherwise hard-cap-
  finalize a cascade bubble whose translation is 2 s away in the MT
  queue, or double-finalize racing the explicit event. `.explicit`
  utterances are closed by `translationText(isFinal: true)`; when
  translation fails, the engine emits that same event with empty text as
  the close, and the store renders the bubble as 中文 + "—" (one
  mechanism, no special store path — the 30 s safety net remains only
  for a lane engine dying mid-utterance).
  Safety net: an `.explicit` bubble with no pipeline activity for 30 s
  finalizes with whatever it has (a lane engine death mid-utterance must
  not leave a bubble open forever), logged as such.
- **Replace-aware sentence counting**: `noteSentenceBoundary` counts
  enders in *appended deltas*; running it on wholesale volatile
  replacements would re-count the same 。 on every revision and
  over-fire the prompter (or, bypassed, never fire it in cascade mode).
  The replace path tracks `countedEnders: Int` per open utterance and
  bumps `sentenceEventTotal` only by the positive delta of enders in the
  new text vs. that counter. `finalizedTotal` bumps on explicit
  finalization exactly once. Net effect: the prompter's two triggers
  (docs/REPLY-FLOW.md §3) fire with the same meaning in both pipelines,
  and the prompter needs no changes.
- **Pinyin**: replaces go through the same 0.3 s-throttled recompute;
  the final replace recomputes unconditionally (same rule as
  finalization today).

## 8. Failure handling & availability

### 8.1 Settings & setup card (Settings → Translation pipeline)

New settings (UserDefaults, `AppSettings` conventions):

- `pipeline` — `"realtime"` (default) | `"cascade"`. **Read once at
  Start**; toggling mid-conversation applies to the next conversation
  (same rule as everything else lanes are built from).
- `cascadeSourceLanguage` — BCP-47, default `"zh-Hans"`. The cascade
  needs an *explicit* source (SpeechTranscriber locale + translation
  source) where realtime auto-detects; the picker is populated from the
  intersection of `SpeechTranscriber.supportedLocales` (via
  `supportedLocale(equivalentTo:)`) and the Translation framework's
  `supportedLanguages`. Behavioral divergence, stated on the picker:
  realtime reads `outputLanguage` per lazy session open (a mid-
  conversation change affects newly opened sessions); the cascade fixes
  the (source, target) pair at Start in `CascadeContext`.
- `laneVoice.<provider>.<language>.<channel>` — §6.4.
- `cascadeSpeechRate` — global TTS rate multiplier (§6.3).
- Existing settings that gain no cascade meaning are simply ignored by
  cascade engines (`noiseReduction` is an OpenAI server-side knob;
  `idleCloseSeconds` is realtime-only per §5.1) — the Settings UI
  annotates them "realtime pipeline only".

Selecting "On-device cascade" reveals a status card with one row per
stage, each showing `ProviderAvailability` (rows localized from
`cascadeSourceLanguage`/`outputLanguage`, shown here for zh→en):

- **Speech recognition (中文)** — installed / [Download] with inline
  `Progress` (AssetInventory, no system sheet) / unsupported.
- **Translation pack (中文 → English)** — installed / [Download] (hosts
  the `.translationTask` view; system sheet appears here and only here) /
  unsupported.
- **Voices** — N usable English voices (+ per-lane assignment summary);
  hint text for downloading premium voices.

Start in cascade mode with anything missing → error banner naming the
missing row (same UX as today's missing-API-key), never a silent fallback
to the paid pipeline.

### 8.2 Runtime failures

| Failure | Behavior |
| --- | --- |
| Admission error while sizing the pool at Start | Normal and silent — that IS the pool-sizing mechanism (§6.1.1): no banner, no `.degraded`; matched by error domain with the code logged (the named-case identity is unconfirmed) |
| A pool slot dies mid-conversation | Recreate once (fresh analyzer, cursor reset, owner re-acquires); repeated death shrinks the pool by one and logs — no lane fails, the cost is shared contention |
| A lane waits > 2 s for a slot | `.degraded("waiting for a speech model — simultaneous speech may lag")`; Diagnostics counts every wait regardless |
| `.notInstalled` from translate (pack deleted) | Stage fatal: transcription continues, translation column shows "—", banner → setup card |
| TTS job error / voice vanished | Job's `onFinished(error:)` → skip audio for that utterance, log; voice re-validation at next Start |
| Anything fatal in a lane | Lane isolates (existing per-lane philosophy); Stop not required |

Reconnect/backoff loops (realtime's biggest complexity) largely don't
exist here — there is no network. What remains is bounded: recreate-once
for the analyzer, and everything else degrades a stage, never the
conversation.

## 9. Diagnostics, metrics, cost

- **Diagnostics pipeline panel**: `LanePipelineStatus.session` becomes
  `LaneEngineSnapshot`. The cascade renderer shows per-stage rows: STT
  (state, volatile/final chars, last finalize latency, pool waits), MT
  (queue depth, last latency), TTS (queue depth, last TTFB, skipped-audio
  count), mirroring the symptom-first style of the realtime panel
  ("gate open but nothing captured" gets a cascade twin: "utterances
  finalized: 0 despite 12 s speech — check STT asset / format").
  `CascadeSnapshot` carries those counters, sampled by the same 1 Hz tick.
- **MetricsStore**: new cascade series from `LaneMetric` (finalize / MT /
  TTS-TTFB / end-to-end percentiles per lane). Existing realtime charts
  unchanged.
- **CostMeter**: unchanged; cascade engines simply never emit
  `onCostDelta`, and the status bar cost line shows "$0.00 · on-device"
  when the conversation runs all-Apple. The prompter's cost (still
  OpenAI) keeps metering as today — the prompter is unaffected by
  pipeline choice and still requires the API key; cascade-only users
  without a key get the prompter disabled with today's existing
  missing-key messaging.

## 10. Hardware probe (CP0) — before any pipeline code

The repo's rule: unverifiable claims get a Diagnostics probe before the
design is trusted (bench test, dual-input probe). One new probe screen,
results pasted into this doc:

1. **Playgrounds compatibility**: `import Translation` + `import Speech`;
   create a headless `TranslationSession`, a `SpeechTranscriber`, and an
   `AVSpeechSynthesizer.write()` render inside the app playground. Also:
   the translation download sheet from a Playgrounds-hosted view, and
   confirmation that a pack-less headless session errors with
   `.notInstalled` at `translate()` time (init non-throwing), plus that
   Playgrounds accepts the `.iOS("26.0")` platform bump.
2. **Concurrent analyzers**: 1→4 zh_CN transcribers on looped recorded
   audio, both incremental AND all-at-once creation (eager open at Start
   is the all-at-once case, §6.1); record where `insufficientResources`
   hits and CPU/thermal. Expectation set by §2.2: identical configs may NOT raise the
   admission limit on iOS 26 — a cap of 1–2 is a plausible result, and
   it reroutes CP2 through a pooled-mode design pass (§11), it does not
   kill the cascade.
3. **Concurrent `write()`**: two/three simultaneous renders, different
   voices; correctness + wall-clock vs serialized.
4. **zh punctuation**: transcribe scripted Mandarin (statements,
   questions, exclamations); inspect finals for 。！？.
5. **Translation latency**: 50 varied zh sentences through one session,
   serialized; p50/p95; then the same via `translations(from:)` batch.
6. **STT finalize latency & boundary tuning**: with/without
   `prepareToAnalyze`, measure VAD-end → final over 20 utterances; on
   the same recordings, measure the spurious-close rate of the two-tier
   debounce (§6.1) at several constants — the 400/750 ms defaults are
   priors, not conclusions.
7. **Voice inventory dump**: `speechVoices()` on the target iPad —
   identifiers, qualities, formats (write one buffer per voice, log
   `buffer.format`).
8. **Sustained load**: a 30-minute 4-lane run on looped audio (STT + MT
   + TTS all active): thermal state notifications, battery drain, and
   whether finalize latency degrades over time. A dinner is 2+ hours of
   this; a one-off CPU number doesn't answer it.

Go/no-go: items 1–2 are gating (a Playgrounds failure forces redesign;
an analyzer cap below the enabled-lane count reroutes CP2 through the
pooled-mode design pass). Items 3–8 tune constants, copy, and
expectations.

### Probe results (2026-07-14, CP0 run on the target iPad, iPadOS 26)

1. **Playgrounds compatibility: PASS across the board.** `import Speech`
   + `import Translation` built and ran inside the app playground; the
   headless `TranslationSession` translated (你好 → Hello) with the pack
   installed; `AssetInventory.downloadAndInstall()` fetched the zh_CN
   model programmatically; the translation-pack system sheet presented
   from the Playgrounds-hosted `.translationTask` view; `write()`
   rendered normally. 30 supported SpeechTranscriber locales on-device,
   zh_CN matched and installed.
2. **Concurrent analyzers: admission limit = 3.** n=1..3 all-at-once ran
   clean; n=4 threw `SFSpeechErrorDomain` code 16 ("Maximum number of
   simultaneous requests reached"). Gate outcome: **pooled mode is the
   primary design (§6.1.1)** — the design pass the phasing gate required
   is done and re-reviewed. Throughput: each run transcribed 10.8 s of
   audio in ~0.3–0.4 s (≥25× real time even 3-wide), which is what makes
   pool contention effectively invisible (burst catch-up typically
   sub-second; ~1.5 s at the 30 s buffer bound).
3. **Concurrent `write()`: 2-wide renders overlap.** Two synthesizers
   rendered simultaneously with complete buffer sets (457/469 buffers).
   The serial-vs-concurrent wall-clock comparison (0.74 s vs 0.11 s) is
   contaminated by voice warm-up in the serial baseline, and 3–4-wide
   was not tested — so the conclusion is exactly this: per-lane
   synthesizers proceed as the design, with §6.3's serial-render
   fallback retained as the contingency. Tingting's `write()` format:
   22 050 Hz, mono, float32 — the sniff-and-convert rule earns its keep.
4. **zh punctuation: present but inconsistent.** 。 and ？ appeared, but
   several sentence boundaries surfaced as `，` and the final sentence
   ended unpunctuated. The transcriber also normalizes ("上午十点" →
   "上午 10:00"). Validates the design's stance: punctuation is an
   accelerator (the 400 ms fast tier fires when it's there), the VAD
   boundary + 12 s split carry the guarantee. `，` is NOT a fast-close
   ender.
5. **Translation latency: negligible.** Cold 210 ms; serial p50 62 ms /
   p95 210 ms over 20 sentences; batch 59 ms/sentence. Serialized
   per-pair sessions are comfortably sufficient; the batch escape hatch
   is unnecessary at dinner-table volumes.
6. **Finalize latency: p50 0.08 s (0.03–0.05 s with
   `prepareToAnalyze`)** on paced, clean TTS audio — ~20× better than
   the public field reports. Pre-warm stays (it still halves the
   number); the §7 budget keeps margin for live far-field audio.
7. **Voice inventory: 180 voices, all default-tier.** No enhanced or
   premium installed on a stock device; the usable-after-filtering set
   is dominated by `com.apple.eloquence.*` and legacy MacinTalk voices —
   hence the ranking floor in §6.4. Genuinely distinct pleasant lanes
   need the one-time enhanced/premium downloads (Settings →
   Accessibility → Read & Speak → Voices).
8. **Sustained load: not yet run** — worth doing before the first long
   dinner; the probe button remains.

## 11. Phasing

- **CP0 — probe** (§10). Includes the `Package.swift` bump to
  `.iOS("26.0")` (the probe exercises iOS 26 APIs; the claim that
  Playgrounds 4.7 implies iPadOS 26 hardware comes from this repo's own
  research and is itself verified by the probe building at all).
  Otherwise zero risk to the running app.
- **CP1 — seam refactor**: `LaneEngine` protocol, `RealtimeLaneEngine`
  adapter, AppModel/Diagnostics/Metrics ported to the seam. Behavior
  change: none — acceptance is the itemized contract in §5.1.1,
  exercised with induced network loss.
- **Gate between CP1 and CP2** — TRIGGERED and SATISFIED: probe item 2
  admitted 3 of 4 lanes, and §6.1.1 is the resulting pooled-mode design
  pass (slots, cursors, FIFO acquisition, burst catch-up), taken through
  the same adversarial review loop as the rest of this document before
  CP2 work began.
- **CP2 — Apple cascade** — SHIPPED (adversarially reviewed, 3 rounds:
  5 majors + 1 blocking latch defect found and fixed pre-merge):
  providers, CascadeLaneEngine, TranscriptStore changes (§7.1),
  settings + setup card + per-lane voices. First real conversations
  validate the §7 latency table next.
- **CP3 — polish** — SHIPPED (reviewed, LGTM): cascade Metrics series +
  chart, on-device cost annotation, Diagnostics symptom rows, body-safe
  voice resolution, README cascade section. (Voice previews, the
  speech-rate slider, and degraded-mode UX had already shipped with CP2.)
- **CP4 — cloud providers** (separate follow-up): OpenAI STT/MT/TTS
  implementations of the same protocols, provider pickers per stage,
  cost plumbing for mixed pipelines. DeepL Voice fused-provider path
  evaluated then.

## 12. Decision log

| Decision | Why |
| --- | --- |
| Seam at `LaneEngine` (per-lane), not a global pipeline object | The lane is the unit everything already keys on (gate, sessions, playback, transcript, diagnostics); realtime adapter becomes trivial |
| Callbacks at the seam, Swift concurrency inside providers | One threading model at the AppModel boundary (audioQueue discipline stays); actors/AsyncSequence stay encapsulated where the OS APIs force them |
| Min OS → iOS 26 | Playgrounds 4.7 already implies iPadOS 26 hardware; kills the view-tied translation hack and `#available` sprawl |
| Cascade drops non-speech audio instead of streaming silence | No continuous-timeline contract to honor (that's an OpenAI-realtime artifact); doubles as Apple's own "interleaved schedule" concurrency mitigation |
| One shared TranslationSession, serialized | No documented concurrent-call support; expected per-sentence cost is small; batch API is the escape hatch |
| TTS via `write()` + own engine playback | Per-lane mixing/ducking is non-negotiable; `speak()` can't do it and destabilizes the session |
| Per-lane synthesizers, global render queue as fallback | Matches unknown concurrency reality without changing the seam |
| SFSpeechRecognizer fallback rejected | One concurrent task device-wide kills the 4-lane design; iOS 26 floor makes it moot |
| v1 translates finals only | Simplicity first; volatile-translate is a bounded, designed-in follow-up if field latency disappoints |
| Audio-skip backpressure (keep text, drop stale speech) | A live table can't use 30 s-old audio; the transcript preserves completeness |
| Personal Voice excluded | Incompatible with `write()` buffer rendering (system falls back to direct output) |
| `GateVerdict.voicedNow` at the seam (genuine voicing: raw VAD minus bleed, pre-hangover) | The 1.5–2.0 s gate hangover exists for gate continuity, not segmentation; the smoothed flag would put it at the head of every cascade response (§7 table), and VAD-without-bleed-subtraction would starve the close debounce on suppressed lanes for whole turns (§5.1) |
| Cascade exempt from idle-close, eager open at Start | Analyzer close is terminal; reopen re-pays seconds of warm-up on the first post-lull utterance to save $0 |
| Engines own format self-healing (sniff `buffer.format` per send) | Route churn changes the hardware rate mid-conversation; a stale STT converter fails silently — AppModel's route-change resampler rebuild moves inside the seam it can no longer see into |
| Utterance provenance flag in TranscriptStore | Quiet-timeout machinery (finalizeStale, reopen, sentence fast path) applied to explicitly-finalized cascade bubbles double-finalizes and truncates; the two segmentation regimes must not touch each other's utterances |
| 12 s max-utterance hard split | Ambient-mode chatter can hold the VAD open for minutes; punctuation (inconsistent for zh per the probe) must stay an accelerator, so a duration bound is the only guaranteed mid-speech release |
| AnalyzerPool as the primary STT topology, sized at runtime | Measured: the target iPad admits 3 simultaneous analyses for 4 lanes; discovery-at-Start turns an undocumented device-dependent limit into a measurement, N ≥ lanes degenerates to static binding with no second code path, and ≥25× real-time throughput makes contention a sub-second event |
| Slot release finalizes through the FULL fed cursor | A `lastSpeechTime` finalize would leave the hangover tail un-finalized on the slot at owner switch, mis-attributing its late results to the next lane — the one hole in the one-owner demux argument (review round 4) |

## 13. Sources

Apple docs: [TranslationSession](https://developer.apple.com/documentation/translation/translationsession) · [init(installedSource:target:)](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)) · [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability) · [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) · [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory) · [speech-permission note](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition) · [AVSpeechSynthesizer.write](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)) · [Playgrounds capabilities](https://developer.apple.com/documentation/swift-playgrounds/project-capabilities)
WWDC: [24-10117 Translation API](https://wwdcnotes.com/documentation/wwdc24-10117-meet-the-translation-api/) · [25-277 SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) · [20-10022 speech experience](https://developer.apple.com/videos/play/wwdc2020/10022/)
Field reports: [SpeechAnalyzer finalize latency (Apple forums 794720)](https://developer.apple.com/forums/thread/794720) · [concurrent SFSpeechRecognizer limits (688484)](https://developer.apple.com/forums/thread/688484) · [write() format bug (684419)](https://developer.apple.com/forums/thread/684419) · [write() callback regression (714984)](https://developer.apple.com/forums/thread/714984) · [iOS 17 TTS breakage (738048)](https://developer.apple.com/forums/thread/738048) · [Personal Voice × write() (736148)](https://developer.apple.com/forums/thread/736148) · [SpeechAnalyzer guide (Gubarenko)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide) · [MacStories hands-on](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/) · [on-device TTS eval (VoicePing)](https://voiceping.net/en/blog/research-offline-tts-eval/) · [neural-voice session pitfall](https://medium.com/@info_4533/why-avspeechsynthesizer-sounds-terrible-on-real-iphones-eb4565862ea8)
Prior art: [Pipecat STTService](https://reference-server.pipecat.ai/en/stable/_modules/pipecat/services/stt_service.html) · [Pipecat TTSService](https://reference-server.pipecat.ai/en/latest/_modules/pipecat/services/tts_service.html) · [LiveKit stt.py](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/stt/stt.py) · [LiveKit tts.py](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/tts/tts.py) · [LiveKit TTS StreamAdapter](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/tts/stream_adapter.py)
Future providers: [OpenAI realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription) · [OpenAI TTS](https://developers.openai.com/api/docs/guides/text-to-speech) · [ElevenLabs stream-input](https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input) · [DeepL Voice](https://developers.deepl.com/api-reference/voice)

## 14. CP4 addendum: OpenAI stage providers (designed 2026-07-15)

Decisions (owner): OpenAI only — ElevenLabs/DeepL deferred; **defaults
stay Apple for all three stages**; the owner's day-to-day target is
Apple STT + **OpenAI translation** + Apple TTS ("chat models handle
context better than Apple's literal translations"), so MT is the
flagship and ships first. Per-lane source language stays on the roadmap,
out of CP4.

### 14.1 OpenAIChatTranslator (the flagship — implementation slice a)

A `Translator` implementation over chat completions, one instance PER
LANE (unlike Apple's shared session): each lane's jobs stay FIFO via the
protocol's internal serialization, while lanes translate in parallel —
at 0.5–1.5 s/request, a shared serial queue would back up behind four
chatty lanes in a way Apple's 62 ms never did.

- **Context is the point**: the request carries (1) the scene line
  (`AppSettings.sceneContext` — already user-maintained for the
  prompter), (2) a rolling window of the last ~6 finalized
  source→translation pairs ACROSS ALL LANES with speaker names (table
  context disambiguates pronouns/ellipsis, which is exactly where
  literal MT fails), and (3) the source utterance. System prompt pins:
  translate SOURCE→TARGET, output the translation only, no
  explanations, preserve register, natural/idiomatic over
  word-for-word. It also declares the input as a raw STT transcript
  with CLOSED correction rules (owner request, post-slice-(a)): fix
  only clear homophone-class mis-recognitions, drop fillers, and when
  unsure translate what is written — never add unsupported content.
  Closed rules on purpose: an open-ended "the transcript may be wrong"
  invites confident confabulation, worst on the parked
  English-into-Mandarin-model case.
  **Mechanism — PUSH, never pull** (a pull closure à la
  `assist.transcriptWindow` does NOT transfer: TranscriptStore is
  main-confined and that closure is only ever called on main, while the
  MT pump runs on the lane queue — and `snapshot()` is already a main →
  lane-queue `queue.sync` at 1 Hz, so a lane-queue → main sync fetch is
  an ABBA deadlock): AppModel builds the window ON MAIN whenever a
  cascade utterance finalizes and pushes a read-only value into every
  cascade engine via `queue.async` (`updateTranslationContext(_:)`);
  the pump reads its cached copy locally. Speaker names are captured at
  push time (laneName is main-confined). This codifies the standing
  seam invariant, now stated: **a lane engine's queue never blocks on
  main.**
  **Window content rules**: exclude the job's OWN utterance (it is
  already a finalized-source row with an empty translation at submit
  time — the model must not see the sentence it's translating as a
  failed exemplar); exclude pairs with empty/"—" translations; exclude
  pairs produced by the Apple fallback (they'd teach the literal style
  this feature exists to avoid).
- **Model**: `cascadeTranslationModel` setting, default `gpt-5-mini`,
  picker fed by the same /v1/models fetch SettingsView already does for
  the prompter. Reasoning-family models get `reasoning_effort:
  "minimal"` (research: MT latency balloons otherwise), mirroring
  whatever AssistEngine/ChatCompletionClient already does — reuse that
  client if its shape fits, else a thin sibling.
- **Streaming**: SSE deltas → the existing `onDelta` hook →
  `translationText(utterance:text:isFinal:false)` replaces live in the
  bubble; TTS waits for the final (unchanged pipeline).
- **Failure & offline**: bounded per-job timeout (8 s). On failure or
  timeout: if the Apple pack for the pair is installed, fall back to
  AppleTranslator FOR THAT JOB (log + Diagnostics counter; the fallback
  translator is created lazily once); else the existing empty-final path
  ("—"). **Single resolution per job is an invariant**: once a job can
  resolve two ways (fallback after timeout vs a late OpenAI success),
  each job resolves exactly once by job identity — late completions are
  dropped (the pool's ResumeOnce discipline; without this, the shipped
  mtFinished path double-fires: a late non-empty final after the bubble
  closed CREATES AN ORPHAN DUPLICATE BUBBLE via cascadeIndex's
  allowCreate, and enqueueTTS speaks the utterance twice).
  **Latch**: failure counting is GLOBAL (CascadeContext — network death
  is global; per-lane counters would serialize up to 4 × 3 × 8 s of
  stalls); 3 consecutive failures latch the fallback and raise the
  banner. Recovery is half-open: a synthetic probe request every ~60 s
  (never a real utterance, so real translations never stall) un-latches
  on success — a 30 s venue-Wi-Fi blip must not cost a 2-hour dinner
  the context-aware translation that is this feature's point.
- **Cost**: token usage from the API response × the model's price via
  the existing AssistPricing table → `onCostDelta`. Unpriced models
  count 0 with the same "excludes unpriced model" caveat the prompter
  shows.
- **Priority tier**: `cascadeTranslationPriority` — a toggle SEPARATE
  from the prompter's (owner request; translation latency is heard in
  the ear every sentence, so its spend knob is its own). Read live per
  request like the prompter's; metered cost is doubled while on
  (AssistPricing is standard-rate, priority bills ~2×).
- **Key requirement**: selecting any OpenAI stage makes the API key
  required at Start again (cascade is keyless only when all-Apple);
  setup card gains a key-status row per OpenAI stage.

### 14.2 OpenAITTSSynth (slice b — small)

`SpeechSynth` over `POST /v1/audio/speech`, `response_format: "pcm"` —
natively 24 kHz mono PCM16 LE, i.e. zero-conversion into the playback
seam. One instance per lane (its voice is fixed per lane); chunked
response bytes stream to `onAudio` as they arrive (trim to Int16
alignment), completion → `onFinished`. Model `gpt-4o-mini-tts`; the 13
static voices surface through the existing per-lane voice UI under
provider id "openai" (keys are already provider-scoped). Failure: job
error → skip audio (existing path); no Apple fallback (a voice change
mid-conversation is worse than one silent utterance). Cost:
$/character via a pricing constant, → onCostDelta.

### 14.3 OpenAIStreamingSTT (slice c — deferred until wanted)

The deliberately-unwritten STT protocol gets extracted here, covering
both topologies behind one engine-facing seam:

```swift
protocol STTSession: AnyObject {           // one per lane per UTTERANCE
    func send(_ buffer: AVAudioPCMBuffer)  // converted to inputFormat
    func endUtterance()                    // VAD close → flush finals
    var onResult: ((STTResult) -> Void)? { get set }   // volatile/final; epoch stamped engine-side
    /// The utterance will NOT finalize (WS death mid-utterance, slot
    /// failure): the engine settles with volatile text, counts the
    /// failure, and lets provider-side reconnect/replacement proceed.
    var onFailure: ((String) -> Void)? { get set }
}
protocol STTProvider: AnyObject {
    var inputFormat: AVAudioFormat? { get async }
    func acquireSession(lane: Int) async -> STTSession?  // suspends under contention
    func teardown() async
}
```

`AnalyzerPoolSTTProvider` adapts the existing pool (acquire →
feed/pad/finishAndRetire mapped inside); `OpenAISTTProvider` holds one
long-lived transcription WebSocket per lane (`session.type:
"transcription"`, `turn_detection: null`, gpt-4o-mini-transcribe,
24 kHz PCM16 input — the realtime client's resampler target, no new
conversion), where `endUtterance` = `input_audio_buffer.commit`,
deltas → volatile, `completed` → final. No admission limit ⇒
acquireSession never waits; reconnect mirrors RealtimeLaneEngine's
contract. Cost: $/audio-minute → onCostDelta. CascadeLaneEngine's
worker keeps its command stream; the pool-specific commands become
provider-internal.

### 14.4 Settings & Diagnostics

- Translation pipeline section gains three per-stage pickers
  (Speech recognition / Translation / Voices), each "Apple (on-device)"
  or "OpenAI (cloud)", DEFAULT APPLE, latched at Start like everything
  else. The setup card shows the selected providers' rows (Apple rows
  as today; OpenAI rows = key present + model reachable) — PLUS, when
  OpenAI MT is selected, the Apple translation-pack row in
  fallback-status form ("offline fallback: installed / not installed —
  download"): the per-job fallback silently depends on it, and a user
  who never installed the pack must not discover that as "—" on every
  outage. Diagnostics adds the matching symptom row ("MT fallback
  unavailable — translation pack not installed").
- Voice menus swap inventory with the TTS provider (static 13 for
  OpenAI); ▶ preview works for both (OpenAI preview does one real
  request, noting it costs a fraction of a cent).
- Diagnostics cascade rows add per-stage provider tags and an MT
  fallback counter; the status bar drops "· on-device" when any cloud
  stage is selected (cost is no longer zero).
- CascadeSnapshot gains mtFallbacks + provider labels; Metrics cascade
  chart needs no change (stages are stages regardless of provider).

### 14.5 Slices & review gates

(a) **SHIPPED** — OpenAIChatTranslator + context window + fallback +
cost + MT picker + key row — the owner's daily driver. Slice-(a) code
touchpoints noted by review, all landed: CascadeContext/engine moved
from concrete AppleTranslator to `any Translator` (context factory
`makeTranslator(lane:)` owns provider-defined cardinality and Stop-time
cancellation); the engine's per-lane FIFO comes from its own
one-in-flight MT pump (not the protocol); the engine's "onCostDelta
never fires" comment died. Implementation notes beyond the design
sketch: `translate` returns `TranslationResult{text, viaFallback}` and
takes the pushed `context` window as a parameter (the engine caches the
window and hands it over per job — the fallback-exclusion rule needs
the engine to KNOW a job fell back, and a flag on the result is
race-free where a side-channel callback is not); the residual-NIT
decisions — the global latch banner rides a context-level
`OpenAITranslationHealth.onNotice` wired by AppModel into the id-keyed
handleNotice (no lane attribution), and the half-open probe's cost
flows through `health.onCostDelta` → CostMeter; a missing FALLBACK pack
surfaces as `TranslationStageError.fallbackUnavailable` (Diagnostics
symptom + snapshot flag), never `TranslationError.notInstalled`, which
would trip the engine's Apple-primary stage-fatal latch and kill a
recoverable cloud stage. OpenAI TTS later stamps TTSVoice.language with
the requested language (its voices are language-agnostic).
(b) OpenAITTSSynth + voice UI
integration. (c) STT protocol extraction + OpenAISTTProvider — deferred
until a use case demands it (mixed-language tables currently parked).
Each slice: adversarial code review to LGTM + a field run before the
next lands.
