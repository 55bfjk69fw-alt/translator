# Translator — real-time DJI Mic 3 → OpenAI → AirPods translation for iPad

An iPad app that live-translates a multi-person Mandarin conversation to English.
Up to four speakers each wear a DJI Mic 3 transmitter; the DJI receiver plugs into
the iPad over USB-C; each speaker's channel is streamed to its own OpenAI
`gpt-realtime-translate` session; translated English audio plays into your AirPods,
and a per-speaker Chinese + English transcript scrolls on screen. Hold the
push-to-talk button to answer in English through your AirPods mic — your words are
translated to Chinese, shown on screen, and playable over the iPad speaker.

Developed and run entirely on the iPad with **Swift Playgrounds 4.7+** — no Mac needed.
See `docs/RESEARCH.md` for the feasibility research behind every design decision.

## Hardware setup

1. **DJI Mic 3 receiver**: set the channel mode to **Q (Quadraphonic)** on the RX
   touchscreen so each of the 4 transmitters gets its own USB channel
   (Settings → Channel Mode). In S (Stereo) mode you only get two mixed channels
   (TX1+TX3 = left, TX2+TX4 = right).
2. On each **transmitter**, enable onboard noise cancelling (Basic, or Strong in loud
   venues) from the RX touchscreen or the DJI Mimo app.
3. Plug the RX into the iPad's USB-C port (use the DJI phone adapter or a USB-C cable).
4. Connect your **AirPods** (Pro 2 / Pro 3 / 4 recommended). They are the *output*;
   the DJI RX is the *input*. iPadOS only allows one active input, which is why the
   AirPods mic is push-to-talk only.

## Getting the app onto your iPad

1. Install **Working Copy** (free for cloning) and **Swift Playgrounds** from the App Store.
2. In Working Copy, clone this repository (branch
   `claude/realtime-translation-dji-airpods-nj9mpm`).
3. In Working Copy, long-press `TranslatorApp.swiftpm` → **Share** → **Save to Files**
   (or use Working Copy's Files integration directly).
4. In the Files app, tap the saved `TranslatorApp.swiftpm` — it opens in
   Swift Playgrounds. Tap **Run**.
5. First run: approve the microphone permission prompt.

To iterate: pull the latest commits in Working Copy and re-open. (Swift Playgrounds
edits the copy, so re-export after pulling, or edit directly in Playgrounds for quick
experiments.)

## First run — bench test (do this before anything else)

The single biggest hardware unknown is whether the DJI RX delivers 4 independent USB
channels to iPadOS (DJI certifies it for GarageBand on iOS; this app is the second test).

1. Open the **Diagnostics** tab.
2. Plug in the RX (Q mode), tap **Start bench test**.
3. Check *Input channels*: **4** means full per-speaker capture —
   tap each TX in turn and watch exactly one meter move per tap.
   **2** means iPadOS is getting the stereo fold-down — the app still works with
   two independent channels (seat TX1+TX3 speakers apart from TX2+TX4).
4. Confirm *Outputs* shows your AirPods as `BluetoothA2DPOutput` — that's the
   high-quality playback path.

## Using the app

1. **Settings** tab: paste your OpenAI API key (stored in the device Keychain),
   name your speakers, and pick options.
2. **Conversation** tab → **Start**. Each connected channel opens its own
   translation session (green dot = live).
3. Mandarin speech on any TX appears as a Chinese transcript with its English
   translation underneath, and the interpreted English audio plays in your AirPods
   (~0.5–1.5 s behind the speaker).
4. **Hold the purple button** to speak English: input switches to your AirPods mic,
   your words appear translated to Chinese, with a play button to speak them over
   the iPad speaker (or enable auto-play in Settings).
5. The status bar shows per-speaker levels, gate state, session health, and a
   running cost estimate (5 sessions ≈ $10/hour ceiling at $0.034/session-minute).

Keep the app in the foreground: Swift Playgrounds apps can't run background audio.
The app disables the screen-idle timer while a conversation is running.

## Signal tab — seeing and tuning the gate

The **Signal** tab is a live workbench for the multi-mic pipeline. It works during
a conversation *and* during a free bench test (no API cost), and analysis only
runs while the tab is visible.

- **Gate timeline** (per channel, last 20 s, dB scale): live level vs. the learned
  noise floor vs. the effective open threshold. Green shading = the gate passed
  audio to the translator; red triangles = suppressed as bleed. This answers
  "why didn't my first word get translated" and "why is a silent mic opening
  sessions" at a glance.
- **Mini transcript**: the latest utterances inline, so gate behavior can be
  matched to what actually got transcribed.
- **Mic-pair correlation matrix**: how alike each voiced pair sounds right now;
  a red border means the pair counted as one source and the quieter copy was muted.
- **Per-channel cards**: scrolling spectrogram (60 Hz–12 kHz, log scale),
  instantaneous spectrum, and a waveform envelope with clip detection.
- **Gate tuning**: sliders for every gate parameter, applied to the running gate
  within 200 ms — watch the threshold line move while someone talks.
- **Freeze / export**: pause all plots and share the window as JSON
  (gate timeline, stats, waveform envelopes, bleed events) for offline analysis.

Note: the bench test now runs the gate with your real settings (it used to run
ungated), so bench meters reflect actual gate behavior too.

## Troubleshooting

- **No USB input listed** — unplug/replug the RX, then Diagnostics → *Select USB input*.
  Check the RX is in USB-C audio mode (not mass storage/firmware mode).
- **Only 2 channels in Q mode** — iPadOS may be taking the stereo descriptor. Try:
  RX plugged in *before* starting the app; toggling Q mode while connected.
  If it persists, the stereo fallback is the design (see research doc).
- **Robotic/low-quality AirPods audio** — something switched the connection to the
  HFP profile. Stop, disconnect/reconnect AirPods, Start again. The app never
  requests the AirPods mic outside push-to-talk precisely to avoid this.
- **Sessions won't open** — check the API key, then the Diagnostics event log.
  If the server rejects `session.update` or event names changed, the payload lives in
  `Realtime/SessionConfig.swift` and the event aliases in
  `Realtime/RealtimeTranslationClient.swift` — both are built to be tweaked from
  logged evidence.
- **Duplicate translations of one speaker** — mic bleed getting past the gate.
  The gate cross-correlates channels and keeps only the loudest copy of a shared
  voice, so duplicates should be rare; if they persist, enable per-TX noise
  cancelling (Basic/Strong) and check the gate is enabled in Settings.
- **A quiet speaker gets cut off mid-sentence** — raise their TX gain (or move the
  mic closer to their mouth) rather than lowering the minimum voice threshold; the
  gate adapts to the room's noise floor automatically.

## Roadmap

- [ ] M6: TestFlight self-install (Apple Developer Program, upload from Playgrounds)
  for a home-screen app; CI (GitHub Actions + fastlane) only if background audio is
  ever required.
- [ ] Evaluate iOS 26 `bluetoothHighQualityRecording` quality during push-to-talk.
- [ ] Head-to-head: Gemini Live translate / Azure Live Interpreter fallbacks.
