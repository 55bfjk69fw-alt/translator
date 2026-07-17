# One-on-one bidirectional mode — research & design (2026-07-17)

Experimental concept, forked off `stable`: a **two-person, two-language
conversation through one shared pair of AirPods**. I speak English wearing a
DJI lav; you speak Mandarin wearing the other DJI lav. You wear the **left**
AirPod and hear my speech translated to Chinese; I wear the **right** AirPod
and hear your speech translated to English. Two translation sessions run at
once, one per direction, each hard-panned to its wearer's ear.

This inverts one core `stable` decision: the user's outbound speech is no
longer delivered by cue cards read aloud (docs/REPLY-FLOW.md) — it is
captured, translated, and *synthesized into the partner's ear*. Everything
else (USB multichannel capture, gate, lazy sessions, transcript) carries over.

```
me (EN, TX1) ──► ch0 ─ gate ─► session A (out: zh) ──► LEFT bud  (partner)
partner (ZH, TX2) ► ch1 ─ gate ─► session B (out: en) ──► RIGHT bud (me)
```

Each person also hears the other's *original* voice acoustically — we're
sitting face to face — so the ear feed is translation-only, arriving
interpreter-style ~0.5–1.5 s behind, exactly like the existing app's English
feed. Nothing needs to duck.

## 1. Research

### 1.1 Splitting one AirPods pair across two heads

- **It works and is a known pattern.** Automatic Ear Detection senses each bud
  in an ear "regardless of whether they're attached to the same head"
  ([MacRumors how-to](https://www.macrumors.com/how-to/share-airpods-with-a-friend/)).
  Both buds belong to one Bluetooth route; iPadOS neither knows nor cares that
  the ears differ.
- The standard advice for shared listening is to enable **Mono Audio** so both
  ears get the full mix. We do the **opposite**: the stereo image *is* the
  router. Mono Audio must be **OFF** (Settings → Accessibility → Audio/Visual),
  and the **L/R Balance slider centered** — both would re-mix the channels.
- **Spatialize Stereo must be Off** (Control Center → long-press volume →
  Spatial Audio). Fixed/Head Tracked modes run stereo through a spatializer
  (HRTF crosstalk by design) and head-tracked would smear channels whenever
  either person moves
  ([Apple Support](https://support.apple.com/guide/airpods/control-spatial-audio-and-head-tracking-dev00eb7e0a3/web)).
- **Ear-removal behavior**: removing one bud makes the system pause *media
  playback* apps ([Apple Support 108764](https://support.apple.com/en-us/108764)).
  Our engine runs under `.playAndRecord` and ignores remote commands, so a
  slipped bud doesn't stop translation. Removing **both** buds can re-route
  output to the iPad speaker — the conversation becomes audible to the room.
  Note in UI copy; Stop before un-earing.
- **A2DP survives** because this design never touches the AirPods mic — both
  mics stay on the DJI TXs over USB, which is the exact Apple-endorsed
  USB-in + A2DP-out combo `stable` already uses (docs/RESEARCH.md §2). Enabling
  HFP would collapse the link to mono *and* phone-call quality; the session
  options already exclude it.
- Comfort/practical: foam or well-fitting silicone tips (AirPods Pro) matter
  twice here — seal = less TTS leakage into the room and into the mics (§1.4).
  Bring alcohol wipes; you're handing someone an earbud.

### 1.2 Steering audio to one ear

`AVAudioPlayerNode` adopts `AVAudioMixing`, whose
[`pan`](https://developer.apple.com/documentation/avfaudio/avaudiomixing/pan)
property applies when a mono source feeds a stereo mixer: `-1.0` = fully
left, `1.0` = fully right; at full deflection the opposite channel gets
nothing (equal-power law endpoint). `EngineGraph` already connects one mono
24 kHz player per lane into `mainMixerNode` — per-lane hard panning is a
one-line-per-lane addition, no graph restructuring. The main mixer renders
stereo whenever the output route is stereo, which A2DP is.

Fallback if pan ever proves leaky on some route: connect each player with an
explicit stereo format and write the mono samples into only one channel of
the buffer. Not expected to be needed.

### 1.3 Capture: two TXs, no Q-mode dependency

Only two transmitters are needed — the kit's stock config, no 3rd/4th TX
purchase. **S (Stereo) mode suffices**: TX1 → left/ch0, TX2 → right/ch1
(docs/RESEARCH.md §1). This sidesteps the app's single biggest hardware
unknown (Q-mode on iPadOS); the 2-channel fold-down that would be a
*degradation* for the 4-speaker app is the *native shape* of this mode. Q
mode with 2 TXs works identically (ch0/ch1 live, ch2/ch3 silent).

### 1.4 The two translation sessions

`gpt-realtime-translate` fits unmodified (docs/RESEARCH.md §4):

- **Output language is per-session** (`session.audio.output.language`), input
  language is auto-detected — so direction is purely a per-lane config value:
  session A `"zh"`, session B `"en"`. `SessionConfig` already takes
  `outputLanguage` per instance; only `AppModel.makeClient` currently feeds
  every lane the same global `AppSettings.outputLanguage`.
- Output voice mimics the speaker — the partner hears a Chinese voice that
  sounds like *me*, which is exactly right for this mode.
- **Cost ceiling: 2 × $0.034/min ≈ $4.08/hr**, under half the 4-speaker
  ceiling. Lazy open + idle close already bill only while someone talks.
- The model's target-language skip (it tends to not re-translate speech
  already in the output language) is *helpful* here: if my mic bleeds the
  partner's Mandarin into session A (output zh), the model has little to do
  with it. The reverse holds for session B. Bleed damage is asymmetrically
  self-limiting — the gate is still the real defense.

### 1.5 Acoustic loops (new failure mode analysis)

Four paths exist between the two mouths, two lav mics, and two buds:

| Path | Risk | Mitigation |
|---|---|---|
| My voice → partner's lav (cross-talk) | Duplicate/garbled lines | Existing `ChannelGate` cross-correlation bleed rejection — this is its designed job, now at 2 channels face-to-face (~1 m) instead of 4 around a table. Bench-validate `bleedCorrelation`/`takeoverMargin` at this geometry. |
| ZH TTS in partner's LEFT bud → partner's lav | **Echo loop**: my words re-enter as Mandarin, come back to my ear as English echo | New path the gate can't see (it only correlates *between input channels*, and TTS is genuine speech to the VAD). Defenses: in-ear seal leakage at a ~40 cm chest mic is far below the gate's SNR floor; validate on the bench. If it ever triggers: we hold the TTS reference signal, so a playback-reference correlation check in the gate is a clean future extension. |
| EN TTS in my RIGHT bud → my lav | Same loop, mirrored | Same. |
| Original voices through the air | None — feature, not bug | Ear feed stays translation-only. |

Overlap ducking (`playEnglishAudio` dropping other lanes to 0.35) must be
**disabled between opposite-ear lanes** — the two feeds go to different
heads and can never mask each other. Ducking a lane because the *other
person's ear* is busy would be a bug in this mode.

### 1.6 Prior art in this repo

`main` (which this branch deliberately does **not** include — forked off
`stable` at e4e1117) merged a cascade pipeline + script gate from
`claude/english-synthesis-chinese-channels-mywhya` that also synthesizes
English-origin speech. If this experiment graduates, audit that work for
cherry-picks (script-gating logic in particular) rather than re-deriving it.

## 2. Design

### 2.1 Mode & roles

New conversation mode in Settings: **One-on-one (two-way)** alongside the
existing multi-speaker mode (which stays the default and untouched).

Two fixed roles with per-role config, defaulting to the concept as described:

| Role | Default TX | Speaks | Hears | Default ear |
|---|---|---|---|---|
| Me | TX1 / ch0 | en | partner translated to **en** | **right** |
| Partner | TX2 / ch1 | zh | me translated to **zh** | **left** |

A **Swap ears** and **Swap mics** control each flips one assignment — wrong
bud handed over or TXs clipped on swapped should be a one-tap fix, not a
re-rigging. Languages are per-role settings (`en`/`zh` defaults) so the same
mode later serves any pair from the model's 13 output languages.

Routing rule: the translation of role X's speech is panned to the *other*
role's ear. (Lane ch0 → session out `zh` → pan to Partner's ear = left.)

### 2.2 Engine changes (`Audio/EngineGraph.swift`)

- `start(playerCount:)` grows an optional per-lane `pan: [Float]` (or a
  post-start `setLanePan(_:lane:)` mirroring `setLaneVolume`). Multi-speaker
  mode passes nothing → center, exactly today's behavior.
- Per-lane *user* gain, multiplied under the ducking volume: the pair shares
  one hardware volume rocker, but the two wearers will want different
  loudness. Two sliders ("My ear" / "Partner's ear") over the existing
  master `outputGain`.

### 2.3 Pipeline changes (`App/AppModel.swift`)

- `makeClient(lane:...)`: output language becomes a per-lane lookup —
  one-on-one mode maps lane→role→target language; multi-speaker keeps
  `AppSettings.outputLanguage` for every lane.
- `playEnglishAudio` (rename to `playTranslatedAudio`): skip the
  overlap-duck when mode is one-on-one (§1.5); apply role pan/gain instead.
- Lanes: build exactly 2 (`min(2, inputChannelCount)`); if the RX shows up
  4-channel (Q mode), ch2/ch3 stay unwired.
- Gate: unchanged mechanically; ship a **mic-profile-style preset** for the
  1 m face-to-face geometry once bench-tuned (AppSettings already has the
  `MicProfile` machinery to hang this on).
- Reply prompter (`AssistEngine`): **off by default in this mode** — the
  partner hears my Chinese from TTS, so cue cards are redundant and their
  LLM cost is dead weight. Leave a toggle; the cards are still useful as a
  "say it myself" fallback when TTS mangles something.

### 2.4 Session config (`Realtime/SessionConfig.swift`)

No changes — `outputLanguage` is already per-instance. Client label becomes
`"me→zh"` / `"partner→en"` for legible logs.

### 2.5 UI

- **Conversation view**: one shared feed, both directions, existing bubble
  styling; each utterance already carries its lane. Direction is implicit in
  the language pair; pinyin rendering (`Support/Pinyin.swift`) now matters on
  the *translated* side of my utterances too (partner-facing Chinese),
  not just on Mandarin source text.
- **Ear check** on Start (this mode only): after the AirPods claim, play a
  short spoken cue per side — "left / 左边" panned full left, then
  "right" panned full right — so a swapped-bud or Mono-Audio-on mistake is
  caught in 3 seconds, before anyone talks. Reuse the `AirPodsClaimChime`
  pattern (generated PCM, no assets).
- **Setup checklist** surfaced on first use of the mode (Diagnostics or a
  Start interstitial), because three of these live in iPadOS Settings where
  the app cannot read or enforce them:
  1. Mono Audio **off** (Accessibility → Audio/Visual)
  2. Balance slider **centered**
  3. Spatialize Stereo **Off** (Control Center)
  4. RX in **S or Q** channel mode; TX1 = my collar, TX2 = partner's
  5. Both buds worn before Start (both-out re-routes audio to the iPad
     speaker)
- **Status bar**: two lane dots instead of four, labeled with role names.

### 2.6 Settings additions (`App/AppSettings.swift`)

`conversationMode` (`multi` | `oneOnOne`), per-role: name, language, ear,
TX channel; per-role ear gain; `oneOnOnePrompterEnabled` (default false).
All flat UserDefaults keys in the existing style.

## 3. Validation plan (bench, before any live conversation)

1. **Stereo isolation**: engine up, pan a test tone full left — confirm
   silence in the right bud (and vice versa) with Spatialize Stereo off,
   then deliberately re-enable Spatialize Stereo / Mono Audio and confirm the
   ear check catches both misconfigurations.
2. **S-mode capture**: RX in S mode with 2 TXs — confirm 2 clean channels,
   one meter per TX (existing bench test screen).
3. **Echo loop probe**: TTS playing into a worn bud at conversation volume,
   wearer silent, lav at chest — confirm the gate stays closed (Signal tab
   RMS/VAD readout). Try worst case: AirPods 4 open-fit at max volume.
4. **Cross-talk at 1 m face-to-face**: both TXs live, one person speaks —
   confirm bleed suppression on the other channel; tune the preset.
5. **Both-directions load**: two sessions streaming simultaneously —
   confirm latency parity with the single-direction app and cost meter
   reading ≈ 2× single-lane rate.

## 4. Open questions / risks

- **TTS-into-mic echo** is the one genuinely new acoustic risk (§1.5); if
  bench probe 3 fails, the playback-reference gate extension becomes part of
  the MVP instead of a future item.
- **Language auto-detect on short utterances**: "uh-huh", names, and
  loanwords may get detected as the wrong source language and skipped.
  Live-test; nothing to configure server-side.
- **Shared volume rocker UX**: hardware volume moves both ears; in-app
  per-ear gains fix steady-state but the rocker will surprise people
  mid-conversation. Acceptable for an experiment.
- **One iPad, two readers**: the transcript faces me; the partner reads
  upside-down. A flipped "table mode" split view is a natural follow-up,
  out of scope for the MVP.
