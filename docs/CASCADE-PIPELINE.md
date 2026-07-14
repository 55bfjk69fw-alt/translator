# Cascade pipeline: modular STT → translation → TTS (design)

Status: **design for review** — nothing here is implemented yet.
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
  initializer that needs no SwiftUI view. It throws if the language packs
  aren't installed (`TranslationError.notInstalled`), and such sessions
  can never trigger downloads (`canRequestDownloads == false`). Apple's
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
  zh_TW, zh_HK, yue_CN, community-dumped from the API since beta 3).
  Match via `SpeechTranscriber.supportedLocale(equivalentTo:)`, not string
  comparison (API reports underscore forms). Confidence: high.
- Assets: downloaded programmatically via
  `AssetInventory.assetInstallationRequest(supporting:)` →
  `downloadAndInstall()` (exposes `Progress`, **no system consent sheet**),
  stored system-wide, offline afterwards. `maximumReservedLocales` is
  deliberately undocumented and device-dependent — read at runtime; we
  need only zh. Asset sizes unpublished. Confidence: high (mechanics),
  low (numbers).
- **Concurrency is the top risk and is explicitly designed-for.** Apple:
  the system "limits simultaneous analyses to a conservative number" and
  throws `insufficientResources` beyond it — but "several simultaneous
  transcription sessions may use the same language and settings, or only
  receive audio in an interleaved schedule" can exceed the naive limit,
  and identically-configured transcribers "share the same backing engine
  instances and models". The `ignoresResourceLimits` override is iOS 27+
  only. **No public data on how many concurrent zh_CN streams a given
  iPad sustains — UNVERIFIED, probe item 2.** Our gate helps: only
  gate-passed speech is fed, so 4 open lanes rarely analyze simultaneously.
  Confidence: high (limits exist & mitigations), unverified (the number).
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
`TranslationSession` (one per language pair, lanes share it), the shared
TTS render queue (if the probe forces serialization), and the analyzer
budget tracker (§6.1 degraded mode).

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
    case idle, starting, running
    case degraded(String)      // running but impaired (e.g. STT pool contention)
    case failed(String)
}

/// Everything between "gated audio for one lane" and "transcript +
/// translated audio out". One instance per lane per conversation.
protocol LaneEngine: AnyObject {
    var label: String { get }

    /// Called on audioQueue for EVERY tap buffer (hardware-rate mono
    /// float32), with the gate's verdicts. The engine decides what to do:
    /// realtime substitutes silence for !gatePassed (continuous-timeline
    /// contract); cascade drops non-speech and derives utterance
    /// boundaries from the speech flag (§6.1).
    func sendAudio(_ buffer: AVAudioPCMBuffer, speech: Bool, gatePassed: Bool)

    func start()
    func close()

    // Callbacks on the engine's private queue; consumers hop to main.
    var onState: ((LaneEngineState) -> Void)? { get set }
    var onTranscript: ((TranscriptEvent) -> Void)? { get set }
    /// 24 kHz mono PCM16 LE — the existing playback seam.
    var onTranslatedAudio: ((Data) -> Void)? { get set }
    /// Monotonic dollar increments (realtime: billed seconds × rate;
    /// Apple cascade: never fires).
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
deltas/audio/billing, and keeps the reconnect loop AppModel runs today
(the reconnect logic moves into the adapter so AppModel stops knowing
about sockets; behavior identical). `sendAudio` keeps the exact current
semantics: gate-suppressed buffers become silence, everything is resampled
to 24 kHz PCM16 and appended.

AppModel changes are mechanical: `clients: [Int: RealtimeTranslationClient]`
becomes `engines: [Int: any LaneEngine]`; `makeClient` becomes a factory
switching on the pipeline setting; `wireClient` wires the new callbacks;
lazy-open-on-speech, idle-close, and disabled-mic close are unchanged and
apply to both engine kinds (for the cascade they bound *resource* use
rather than billing).

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
    /// One shared translator per language pair per conversation.
    func makeTranslator(from: Locale.Language, to: Locale.Language) async throws -> any Translator
}

protocol Translator: AnyObject {
    /// Serialized internally; callers may invoke from any queue. Future
    /// streaming providers can deliver via onDelta before returning.
    func translate(_ text: String) async throws -> String
    var onDelta: ((UUID, String) -> Void)? { get set }   // optional streaming hook
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
    /// Jobs are FIFO per synth instance. Audio arrives as 24 kHz mono
    /// PCM16 chunks (providers convert internally), bracketed by
    /// onFinished per job.
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

Per lane: one long-lived `SpeechAnalyzer` in autonomous mode
(`start(inputSequence:)`) with one `SpeechTranscriber` configured
identically across lanes (locale from the source-language setting via
`supportedLocale(equivalentTo:)`, preset `.progressiveTranscription`
(volatile + fast), no `audioTimeRange` in v1) — identical configs are what
lets the OS share one backing engine across lanes.

- **Input**: the lane engine converts gate-passed buffers to
  `bestAvailableAudioFormat(compatibleWith: [transcriber])` (queried once
  at start; expected 16 kHz mono) with a dedicated `AVAudioConverter`,
  wraps them in `AnalyzerInput`, and yields into the stream's
  continuation. Non-speech buffers are *not* sent (unlike realtime's
  silence-substitution) — this is the "interleaved schedule" mitigation
  from Apple's own concurrency guidance, and it means the analyzer's
  audio clock only advances during speech.
- **Segmentation**: an utterance opens on the first speech buffer after
  quiet. When the gate's speech flag has been false for 300 ms
  (debounce; the gate hangover already smoothed word gaps), the engine
  calls `endUtterance()` → `finalize(through: lastSpeechTime)`, which
  forces the final result for the segment without ending the session.
  A monologue that never pauses is split anyway: when a *final* result
  arrives mid-utterance ending in sentence punctuation (。！？.!?), the
  accumulated sentence(s) are released downstream as a sub-segment —
  same trick TranscriptStore's sentence-timeout uses today. Punctuation
  is an accelerator, never a requirement (zh punctuation is unverified):
  the VAD boundary alone always produces a translatable segment.
- **Results**: volatile results replace the utterance's source text live
  (`.sourceText(utterance:text:isFinal:false)`) — Chinese appears on
  screen *while the person talks*, which the realtime pipeline never did.
  The final result replaces it once more and feeds translation.
- **Warm-up**: `prepareToAnalyze(in:)` for every enabled lane at Start
  (halves finalize latency; ANE-state variance noted in research).
- **Assets**: `AssetInventory` request at setup time with `Progress`
  surfaced in the setup card (§8.1); `.assetUnavailable` at Start →
  banner pointing at the card.
- **Degraded mode (insufficientResources)**: if creating analyzer N
  throws, the provider drops to a *pooled* mode: N−1 analyzers serve all
  lanes, acquired per utterance (gate-open) and released at finalize.
  Overlapping speech beyond the pool buffers up to 30 s of audio per lane
  (same bound as the realtime pre-open queue) and transcribes on release —
  text arrives late rather than never, `LaneEngineState.degraded`
  ("2 speech models for 4 mics — simultaneous speech may lag") makes it
  visible, and the Diagnostics row shows pool waits. Pool acquisition
  order is FIFO by utterance start. This is also the fallback if the
  probe finds the device caps at 1–2 analyzers.

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
  ducking untouched. Zero-length buffer → `onFinished`.
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

- **Storage**: `AppSettings.laneVoice(provider: String, channel: Int)` →
  `"laneVoice.\(provider).\(channel)"` (UserDefaults, same pattern as
  speaker names). Stored value is the provider-scoped voice identifier.
- **Defaults**: on first use (or when a stored voice fails validation),
  auto-assign distinct voices: enumerate `voices(for: outputLanguage)`,
  rank premium > enhanced > default, interleave gender/accent variety
  (en-US/en-GB mix), assign index-wise per channel, then persist so the
  assignment is stable ever after.
- **Validation**: at Start, `AVSpeechSynthesisVoice(identifier:)` nil →
  log, banner-note, auto-reassign (voices are deletable/purgeable).
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
- **Cancellation**: Stop / idle-close calls `close()`: STT
  `finalizeAndFinishThroughEndOfInput()` with a 3 s drain cap (mirrors
  the realtime close drain), `Translator.cancelAll()`,
  `SpeechSynth.cancelAll()`, then state `.idle`. In-flight utterances
  finalize into the transcript if the drain returns them in time.
- **Latency budget** (expected, to be validated by probe):

| Stage | Expected |
| --- | --- |
| Live Chinese on screen (volatile) | 0.3–0.5 s behind speech |
| Speech-end → final Chinese | ~1.0–2.0 s (with pre-warm) |
| Final → translation (Apple, on-device) | unmeasured publicly; probe. Working assumption ≤ 0.3 s/sentence |
| Translation → first translated audio | ~0.1–0.5 s (warm voice) |
| **Speech-end → translated audio** | **~1.5–3 s** (vs realtime's 0.5–1.5 s mid-speech) |

The cascade trades interpreter-style overlap for: source text *ahead* of
the realtime pipeline (volatile results beat the whisper stream's lag),
offline operation, $0, and voice-per-speaker. That trade is the point;
the doc states it so nobody expects realtime parity. The designed-in
mitigations if field latency disappoints, in order: translate on the
volatile text at VAD-end and reconcile when the final differs (research:
~95% match on short utterances), sentence sub-segmentation (§6.1, already
in v1), and `.lowLatency` strategy pinning (26.4).

## 8. Failure handling & availability

### 8.1 Setup card (Settings → Translation pipeline)

Selecting "On-device cascade" reveals a status card with one row per
stage, each showing `ProviderAvailability`:

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
| Analyzer throws `insufficientResources` at open | Pooled degraded mode (§6.1), lane state `.degraded`, banner once |
| Analyzer dies mid-conversation | Recreate once (same slot); second death → lane `.failed`, other lanes unaffected |
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
   the translation download sheet from a Playgrounds-hosted view.
2. **Concurrent analyzers**: 1→4 zh_CN transcribers on looped recorded
   audio; record where `insufficientResources` hits and CPU/thermal.
3. **Concurrent `write()`**: two/three simultaneous renders, different
   voices; correctness + wall-clock vs serialized.
4. **zh punctuation**: transcribe scripted Mandarin (statements,
   questions, exclamations); inspect finals for 。！？.
5. **Translation latency**: 50 varied zh sentences through one session,
   serialized; p50/p95; then the same via `translations(from:)` batch.
6. **STT finalize latency**: with/without `prepareToAnalyze`, measure
   VAD-end → final over 20 utterances.
7. **Voice inventory dump**: `speechVoices()` on the target iPad —
   identifiers, qualities, formats (write one buffer per voice, log
   `buffer.format`).

Go/no-go: items 1–2 are gating (a Playgrounds or 2-analyzer failure
forces redesign — pooled mode §6.1 becoming the default, or the cascade
shipping as 2-lane). Items 3–7 tune constants and copy.

## 11. Phasing

- **CP0 — probe** (§10). Ships alone; zero risk to the running app.
- **CP1 — seam refactor**: `LaneEngine` protocol, `RealtimeLaneEngine`
  adapter, AppModel/Diagnostics/Metrics ported to the seam. Behavior
  change: none (the acceptance test is a realtime conversation
  indistinguishable from today's, plus the existing reconnect banners).
- **CP2 — Apple cascade**: providers, CascadeLaneEngine, TranscriptStore
  replace-path, settings + setup card + per-lane voices. First real
  conversations; latency table (§7) validated and filled in.
- **CP3 — polish**: cascade Diagnostics/Metrics rendering, degraded-mode
  UX, voice previews, speech-rate slider, README/docs.
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

## 13. Sources

Apple docs: [TranslationSession](https://developer.apple.com/documentation/translation/translationsession) · [init(installedSource:target:)](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)) · [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability) · [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) · [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory) · [speech-permission note](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition) · [AVSpeechSynthesizer.write](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)) · [Playgrounds capabilities](https://developer.apple.com/documentation/swift-playgrounds/project-capabilities)
WWDC: [24-10117 Translation API](https://wwdcnotes.com/documentation/wwdc24-10117-meet-the-translation-api/) · [25-277 SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) · [20-10022 speech experience](https://developer.apple.com/videos/play/wwdc2020/10022/)
Field reports: [SpeechAnalyzer finalize latency (Apple forums 794720)](https://developer.apple.com/forums/thread/794720) · [concurrent SFSpeechRecognizer limits (688484)](https://developer.apple.com/forums/thread/688484) · [write() format bug (684419)](https://developer.apple.com/forums/thread/684419) · [write() callback regression (714984)](https://developer.apple.com/forums/thread/714984) · [iOS 17 TTS breakage (738048)](https://developer.apple.com/forums/thread/738048) · [Personal Voice × write() (736148)](https://developer.apple.com/forums/thread/736148) · [SpeechAnalyzer guide (Gubarenko)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide) · [MacStories hands-on](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/) · [on-device TTS eval (VoicePing)](https://voiceping.net/en/blog/research-offline-tts-eval/) · [neural-voice session pitfall](https://medium.com/@info_4533/why-avspeechsynthesizer-sounds-terrible-on-real-iphones-eb4565862ea8)
Prior art: [Pipecat STTService](https://reference-server.pipecat.ai/en/stable/_modules/pipecat/services/stt_service.html) · [Pipecat TTSService](https://reference-server.pipecat.ai/en/latest/_modules/pipecat/services/tts_service.html) · [LiveKit stt.py](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/stt/stt.py) · [LiveKit tts.py](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/tts/tts.py) · [LiveKit TTS StreamAdapter](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/tts/stream_adapter.py)
Future providers: [OpenAI realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription) · [OpenAI TTS](https://developers.openai.com/api/docs/guides/text-to-speech) · [ElevenLabs stream-input](https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input) · [DeepL Voice](https://developers.deepl.com/api-reference/voice)
