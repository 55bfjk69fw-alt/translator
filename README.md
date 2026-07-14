# Translator — real-time DJI Mic 3 → OpenAI → AirPods translation for iPad

An iPad app that live-translates a multi-person Mandarin conversation to English.
Up to four speakers each wear a DJI Mic 3 transmitter; the DJI receiver plugs into
the iPad over USB-C; each speaker's channel is streamed to its own OpenAI
`gpt-realtime-translate` session; translated English audio plays into your AirPods,
and a per-speaker Chinese + English transcript scrolls on screen. To reply, the
**reply prompter** watches the conversation and keeps 2–3 things you could say
ready as cue cards — Chinese with tone-marked pinyin that *you read aloud
yourself* (nothing is ever played by the iPad) — and a composer turns anything
you type into the same kind of card. See `docs/REPLY-FLOW.md` for the design.

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
   the DJI RX is the *input*. iPadOS publicly allows one active input, so the
   AirPods mic is never used (except by the Diagnostics dual-input probe).
   If the AirPods are currently on your **iPhone**, just tap **Start**: the app
   briefly plays a start chime under a media-playback session — the "this device
   started playing" signal that iPadOS automatic switching listens for (the same
   thing YouTube does when you hit play) — so the AirPods hop to the iPad on
   their own. Hear the chime in your ears and the handoff worked; hear it from
   the iPad speaker and it didn't — check Settings → Bluetooth → AirPods →
   **Connect to This iPad** → **Automatically** (and note the iPad can't steal
   them mid-phone-call). Toggleable in Settings → Playback.

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

## Dual-input probe — can the AirPods mic run beside the DJI?

iPadOS publicly allows one active input route, which is why the AirPods are
output-only. But Apple's Live Translation captures the AirPods mics *alongside*
the phone's active input through a private path, and it works with a DJI RX
plugged in — so **Diagnostics → Dual-input probe** tests whether any public API
reaches the same capability on this hardware (no API cost):

1. Stop any conversation/bench test, connect AirPods and the RX, tap
   **Start probe**. The probe configures USB as the input with Bluetooth
   options enabled (including the iOS 26 high-quality recording link) and taps
   it — the per-channel meters should move when you tap the TXs.
2. Tap **Start capture stream**. This runs a second, independent capture stack
   (`AVCaptureSession`, on its own private audio session by default) and
   meters whatever it hears.
3. **The decisive test**: pocket or power off every DJI TX, then speak.
   - Capture meter moves while the USB meters stay flat → the AirPods mic is
     genuinely live next to USB. 48 kHz in the capture format line means the
     HQ link; 8–16 kHz means HFP.
   - Starting capture kills the USB meters (route stolen) → the classic
     single-input collapse.
4. The **Prefer BT / Prefer USB input** buttons run the route-flip experiment
   explicitly, and **Restart USB tap** recovers the engine after a flip. Every
   observation lands in the shareable probe log — paste the result into
   `docs/RESEARCH.md` either way.

If the probe succeeds, the AirPods mic can become an always-on personal lane
(your own speech captured without wearing a TX) while the DJI channels keep
translating the table.

## Using the app

1. **Settings** tab: paste your OpenAI API key (stored in the device Keychain),
   name your speakers, and pick options.
2. **Conversation** tab → **Start**. Each connected channel opens its own
   translation session (green dot = live).
3. Mandarin speech on any TX appears as a Chinese transcript with its English
   translation underneath, and the interpreted English audio plays in your AirPods
   (~0.5–1.5 s behind the speaker).
4. **Replying**: the suggestion tray above the composer fills with 2–3 things you
   could say (each labeled with who it responds to). Tap a chip for its **cue
   card** — big hanzi + pinyin + what it means — read it aloud, then tap
   **"I said this"** to record it into the transcript. Type anything into the
   composer for a custom card. Long-press any bubble to get replies scoped to
   that exchange (**Reply to this**) or a nuance breakdown (**Explain this**).
   Long-press a chip to **pin** it for the right lull. Set the per-meal scene
   line (who/where/what) from the chip above the tray, and your bio + Mandarin
   level in Settings → Reply prompter — both feed the suggestions.
5. The status bar shows per-speaker levels, gate state, session health, and a
   running cost estimate (4 sessions ≈ $12/hour ceiling at $0.034/session-minute
   translation plus ≈$0.017/session-minute source transcription; the prompter
   adds roughly $2–3/hour during continuous chatter at mini-model pricing).

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

## Ambient mode — walking around, listening to dialogue near you

The default tuning assumes each mic is clipped to the person speaking, so it
deliberately *suppresses* faint far-away speech as bleed. To instead carry a
mic yourself (on your chest, or a second one in your hand) and translate
conversations happening around you, switch **Settings → Signal quality →
Mic placement** to **Ambient (carried)**. This swaps in a second tuning
profile without touching the worn-mic one — each profile remembers its own
settings, so flipping back restores your current setup exactly. What the
ambient profile changes:

| Tunable | Worn | Ambient | Why |
| --- | --- | --- | --- |
| Minimum voice threshold | 0.004 | 0.001 | Speech from 1–4 m away is ~15–25 dB quieter than mouth-distance speech; the worn floor would gate all of it. |
| VAD open probability | 0.50 | 0.35 | Silero scores far-field speech less confidently. |
| Hangover | 1.5 s | 2.0 s | Low-SNR speech reads as choppier; longer hold avoids chopped sentence endings. |
| SNR factor (fallback mode) | 3.0× | 2.0× | Distant speech rises less above the room floor. |
| Steady-noise timeout | 6 s | 12 s | Multi-person chatter around you legitimately stays voiced longer than one wearer ever does. |
| Server noise reduction | near field | far field | OpenAI's far-field mode suits a distant/roaming mic. |

Practical notes for ambient use:

- **Chest + hand pair**: both mics hear the same conversation, so they
  correlate strongly and bleed rejection keeps only the louder copy — that's
  what prevents duplicate translations, no extra setup needed. The hand mic,
  pointed at whoever's talking, usually wins; name the channels "Chest" and
  "Hand" in Settings so the transcript shows which one did. Switch off the
  TX channels you aren't carrying.
- **Transmitter settings matter more than app tuning**: raise the TX gain
  (far-field speech needs it), and keep onboard noise cancelling at **Basic**
  or off — **Strong** is tuned to isolate a close wearer and will eat exactly
  the distant speech you're trying to catch.
- **Attribution changes meaning**: a lane's transcript label is the *mic*,
  not the speaker — everyone the mic hears lands on that one lane.
- **Expect more gate-open time and higher cost**: the gate now opens for any
  nearby speech (including strangers'), and busy environments will trigger
  it often. Watch the running cost estimate, and use the **Signal** tab in a
  free bench test to sanity-check levels first: distant speech should ride
  visibly above the threshold line on the gate timeline; if it doesn't,
  raise TX gain before touching the sliders.
- **Your own voice** still lands on your chest mic loudest of all — it will
  be transcribed/translated like anyone else's. That's usually fine
  (it keeps both sides of your conversations in the transcript).

The Signal tab's gate-tuning panel has the same profile switch, so you can
A/B the two profiles live against real audio and fine-tune the ambient one
(its sliders cover a lower threshold range) without disturbing the worn
profile.

## Troubleshooting

- **No USB input listed** — unplug/replug the RX, then Diagnostics → *Select USB input*.
  Check the RX is in USB-C audio mode (not mass storage/firmware mode).
- **Only 2 channels in Q mode** — iPadOS may be taking the stereo descriptor. Try:
  RX plugged in *before* starting the app; toggling Q mode while connected.
  If it persists, the stereo fallback is the design (see research doc).
- **Robotic/low-quality AirPods audio** — something switched the connection to the
  HFP profile. Stop, disconnect/reconnect AirPods, Start again. The app never
  requests the AirPods mic (outside the Diagnostics probe) precisely to avoid this.
- **Sessions won't open** — check the API key, then the Diagnostics event log.
  If the server rejects `session.update` or event names changed, the payload lives in
  `Realtime/SessionConfig.swift` and the event aliases in
  `Realtime/RealtimeTranslationClient.swift` — both are built to be tweaked from
  logged evidence.
- **Gate shows open but nothing appears in the conversation** — open
  Diagnostics → *Translation pipeline*. Each speaker row traces the whole
  chain: gate state, session state, audio sent (total vs. actual speech —
  a session streams silence while its speaker is quiet, so "60s audio, 0s
  speech" means nothing was ever captured to translate), and what each
  server stream has returned with per-stream freshness ("never" = that
  stream has produced nothing this connection). Orange symptom lines call
  out the broken link, and the same signatures land in the event log
  within ~20 s of enough speech being sent.
- **Translated audio arrives but the Chinese text is missing** — the source
  transcript is a separate server stream that must be enabled via
  `session.update`. Check *Source transcription* in the pipeline row:
  "absent from server ack" means the server ignored or rejected the
  transcription config, and that connection will never send source text —
  the full `session.updated` ack payload is now logged in Diagnostics, so
  the accepted schema can be read off it and `Realtime/SessionConfig.swift`
  adjusted to match. "confirmed" with source chars at 0 means the config
  was accepted but the stream is silent (the client logs a warning for
  this too). Also note the Chinese transcript normally trails the English
  translation by a couple of seconds and can arrive as one late burst —
  bubbles fill in retroactively for up to 10 s after finalizing.
- **Duplicate translations of one speaker** — mic bleed getting past the gate.
  The gate cross-correlates channels and keeps only the loudest copy of a shared
  voice, so duplicates should be rare; if they persist, enable per-TX noise
  cancelling (Basic/Strong) and check the gate is enabled in Settings.
- **A quiet speaker gets cut off mid-sentence** — raise their TX gain (or move the
  mic closer to their mouth) rather than lowering the minimum voice threshold; the
  gate adapts to the room's noise floor automatically.
- **Every mic reads as active with noise cancelling off** — with NC disabled the
  TXs pass constant hiss/room noise. The gate reclassifies any channel that stays
  "voiced" for 6 s without a single pause as steady noise and raises its floor
  past it, so channels settle down within ~10 s of Start. For mics you aren't
  using at all, switch them off in Settings → Speakers — a disabled channel is
  hard-muted and never opens a session.

## Roadmap

- [ ] M6: TestFlight self-install (Apple Developer Program, upload from Playgrounds)
  for a home-screen app; CI (GitHub Actions + fastlane) only if background audio is
  ever required.
- [ ] AirPods personal capture lane (transcribe the user's own speech hands-free)
  if the dual-input probe proves AirPods mic + USB can run together
  (docs/REPLY-FLOW.md §8).
- [ ] Head-to-head: Gemini Live translate / Azure Live Interpreter fallbacks.
