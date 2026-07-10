# Feasibility research (2026-07-09)

Condensed findings behind the app's design. Four research tracks: DJI Mic 3
hardware, iPadOS audio architecture, on-iPad development routes, and the OpenAI
Realtime API. Confidence noted where it matters.

## 1. DJI Mic 3

- **4 TX → 1 RX** simultaneously (up from 2 on Mic 2). Kit ships 2 TX; 3rd/4th sold
  separately. ([DJI FAQ](https://www.dji.com/mic-3/faq))
- RX channel modes: **M** (mono mix), **S** (stereo: TX1+TX3 = L, TX2+TX4 = R),
  **Q (Quadraphonic)**: all four TXs on independent channels — but only over USB
  (the 3.5 mm jack stays stereo).
- **Q mode on iOS is DJI-certified for GarageBand** per DJI's official
  [Quadraphonic Computer Software Compatibility List (PDF)](https://dl.djicdn.com/downloads/DJI%20Mic%203/20250828/COMPATIBILITY_LIST/DJI_Mic_3_Quadraphonic_Computer_Software_Compatibility_List_EN.pdf).
  Since iOS only supports class-compliant USB audio (no third-party drivers), the RX
  must be a standard multichannel UAC device → any AVAudioSession app *should* see
  4 channels. No independent third-party confirmation yet — hence the app's bench test.
- Wireless/USB feed is **48 kHz / 24-bit**; 32-bit float exists only in each TX's
  internal backup recording. Optional "Lossless Audio" (uncompressed link) halves range.
- Per-TX **noise cancellation**: Basic / Strong; plus adaptive gain, low-cut, tone presets.
- RF link latency: no official spec; expect ~20–40 ms (community measurements of
  Mic 1/2/3). Bluetooth-direct TX→iPad exists but is useless here: one usable TX,
  16 kHz/16-bit, ~100 ms.
- iPads are absent from DJI's mobile compatibility list (iPhones only) — community-
  verified territory. RX draws bus power; supports pass-through charging.

## 2. iPadOS audio architecture

- **One active input route, system-wide, ever.** Apple staff confirm even
  `.multiRoute` supports a single input (last-in wins); no aggregate devices on iOS.
  → DJI RX + AirPods mic simultaneously is architecturally impossible.
  ([QA1799](https://developer.apple.com/library/archive/qa/qa1799/_index.html),
  [forums 12710](https://developer.apple.com/forums/thread/12710))
- **USB-in + AirPods-A2DP-out is a supported combo**: `.playAndRecord` with option
  `.allowBluetoothA2DP` and *not* `.allowBluetooth`(HFP). Apple-lab-endorsed pattern.
  ([forums 741513](https://developer.apple.com/forums/thread/741513))
- Multichannel USB capture is mature on iPadOS (8+ channel interfaces work in DAWs).
  Request channels via `setPreferredInputNumberOfChannels`, verify `inputNumberOfChannels`.
  AVAudioEngine exposes one N-channel bus on `inputNode`.
- `.multiRoute` excludes Bluetooth entirely — dead end for AirPods.
- AirPods mic classically forces the whole link to HFP (phone-call quality).
  iPadOS 26 adds `bluetoothHighQualityRecording` (H2 AirPods: Pro 2+, AirPods 4):
  high-quality BT recording link, default mode only, "may increase input latency",
  "not recommended for real-time communication", not in the EU.
  ([WWDC25 session 251](https://developer.apple.com/videos/play/wwdc2025/251/))
- Latency budget: USB in ~10 ms; AirPods A2DP out ~150–250 ms; both negligible vs
  the translation pipeline (~0.5–1.5 s).
- Echo cancellation: avoid Apple voice processing with USB inputs (built for
  handset use; known crashes with route changes). In-ear playback + lav mics means
  AEC is largely unnecessary.
- Background audio works for full apps (`audio` background mode) but that
  entitlement is NOT available to Swift Playgrounds app playgrounds → foreground-only
  until the app graduates to a CI-built Xcode project.

## 3. On-iPad development

- **Swift Playgrounds 4.7** (Mar 2026, Swift 6 + iOS 26 SDK): full SwiftUI apps built
  and run on-iPad. Available: Microphone capability (AVFoundation), Bluetooth,
  networking incl. `URLSessionWebSocketTask`, SwiftPM source packages.
  Not available: background modes, arbitrary entitlements, binary frameworks
  (→ no libWebRTC), app extensions, real debugger.
  ([capabilities doc](https://developer.apple.com/documentation/swift-playgrounds/project-capabilities))
- Playgrounds apps run inside the Playgrounds app; home-screen install goes through
  App Store Connect + TestFlight (uploadable directly from the iPad; $99/yr).
- Xcode for iPad still does not exist (as of WWDC 2026).
- Safari/PWA route rejected: getUserMedia is mono-biased (no multichannel), no
  `setSinkId` on iOS, mic activation forces speaker/HFP re-routes.
- Escape hatch if background audio or WebRTC ever needed: GitHub Actions macOS
  runner + fastlane match → TestFlight, managed entirely from the iPad.

## 4. OpenAI Realtime API (mid-2026)

- **`gpt-realtime-translate`** (launched with GPT-Realtime-2, ~May 2026): dedicated
  streaming speech-translation model. Continuous audio in → translated audio out in
  ~200 ms chunks *while the speaker talks* (interpreter-style; no turns, no VAD
  config). 70+ input languages auto-detected; 13 output languages incl. **en** and
  **zh**. Emits source AND translated transcript deltas. No custom prompts, no
  glossary, output voice mimics the speaker.
  ([model page](https://developers.openai.com/api/docs/models/gpt-realtime-translate),
  [cookbook guide](https://developers.openai.com/cookbook/examples/voice_solutions/realtime_translation_guide))
- Official pattern for multi-speaker: **one translation session per speaker →
  target language**; keep tracks separate; duck-don't-mute originals.
- Transport: WebRTC (browsers/mobile recommended) or **WebSocket**
  (`wss://api.openai.com/v1/realtime/translations?model=…`) with
  `Authorization: Bearer` — fine from a native app. WebSocket chosen because the
  libWebRTC binary can't build in Swift Playgrounds.
- **Verified wire protocol (July 2026, from the API reference — implemented
  exactly in `Realtime/RealtimeTranslationClient.swift`):**
  - Do NOT send `OpenAI-Beta: realtime=v1` (beta shut down 2026-05-12;
    rejected with `beta_api_shape_disabled`).
  - Client events (exactly 3): `session.update`,
    `session.input_audio_buffer.append` (base64 in `audio`), `session.close`.
  - Server events (exactly 7): `error`, `session.created`, `session.updated`,
    `session.closed`, `session.input_transcript.delta`,
    `session.output_transcript.delta`, `session.output_audio.delta` — all
    payloads in `delta`. **No done/completed events, no segment boundaries,
    no item ids**; utterance segmentation must be client-side (quiet timeout).
  - `session.update` surface: only `audio.output.language`,
    `audio.input.transcription.model`, `audio.input.noise_reduction.type`
    (`near_field`/`far_field`/null). No prompts, voice, formats, VAD.
  - Audio format fixed both directions: 24 kHz PCM16 mono LE (not
    configurable). Output arrives as 200 ms frames; append input in 200 ms
    chunks for best behavior. Stream continuously including silence — a send
    gap is treated as contiguous audio, not a pause.
  - Graceful shutdown: send `session.close`, stop appending, keep reading
    until `session.closed` (server flushes remaining output), then drop the
    socket. Closing immediately loses draining output.
  - Language codes: ISO-639-1 (`"zh"`, `"en"`). Billing: duration-based
    $0.034/min ("realtime audio duration"; streamed-vs-connected not
    disambiguated — since silence must be streamed, they converge).
- Reported end-to-end: ~300–800 ms speech → translated audio.
- Pricing: **$0.034/min per session** → 5 sessions ≈ **$10.20/hr ceiling**
  (billing basis wall-clock vs active speech unconfirmed — the app meters it).
  Rate limits: minutes-of-audio/min (Tier 1 = 50) — 5 streams is comfortably within.
- Transcription-only fallback: `gpt-realtime-whisper` ($0.017/min, streaming, tunable
  delay) or `gpt-4o-transcribe` (~$0.006/min); cascade (STT→LLM→TTS) lands ~2–3 s.
- Known risk: Mandarin–English **code-switching** — the translate model tends to skip
  speech already in the target language, leaving gaps. Mitigation: duck the original
  under the translation rather than muting; test with real speakers.
- Alternatives if OpenAI disappoints: Gemini 3.5 Live Translate (preview),
  Azure Speech Translation / Live Interpreter (most mature, strong Chinese),
  Deepgram/ElevenLabs cascade, Apple SpeechAnalyzer (free on-device ZH captions).

## Design consequences

| Decision | Driven by |
|---|---|
| Native Swift Playgrounds app, not web | Safari mono capture + broken output routing |
| WebSocket, not WebRTC | No binary frameworks in Playgrounds |
| One session per DJI channel | OpenAI cookbook pattern; per-speaker transcripts |
| AirPods = output only; push-to-talk switches input | iPadOS single-input rule |
| Gate replaces bleed with silence (not dropped) | Continuous-audio expectation of translation sessions |
| Voicing via pure-Swift Silero VAD port, not an energy threshold | Energy gates false-open on lav rustle (phantom paid sessions, hallucinated lines) and miss quiet speakers in loud rooms; no binary frameworks in Playgrounds rules out ONNX Runtime, and a Core ML conversion can't be built or debugged iPad-only, so the 16 kHz graph (~310k params, MIT) is reimplemented in Swift and verified to ~1e-6 against onnxruntime (`tools/silero/`) |
| Bench test screen first | Q-mode-on-iPad is DJI-certified but community-unverified |
| Foreground-only, idle timer disabled | No background-audio entitlement in Playgrounds |
