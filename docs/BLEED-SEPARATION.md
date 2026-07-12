# Bleed separation at a chaotic dinner party — problem-space exploration (2026-07-12)

Field observation that prompted this: at a dinner party with multiple
overlapping conversations, the gate's assumptions start to crack. This doc
maps the problem space for going beyond binary gating — up to and including
actually *removing* speaker 1's voice from speaker 3's channel when it is
louder on mic 1 — without implementing anything yet. Companion to
`docs/RESEARCH.md`; the current gate is `Audio/ChannelGate.swift`.

## 1. What the gate does today, and exactly where it breaks

Today's pipeline makes one **binary decision per channel per 200 ms buffer**:
pass the buffer verbatim, or replace it with silence. The decision combines
per-channel Silero VAD voicing with pairwise cross-correlation bleed
rejection (both voiced + peak correlation ≥ 0.55 within ±25 ms lag → the
quieter channel is suppressed; ties broken with a 1.25× takeover margin),
plus a 1.5 s hangover.

This design is built on three assumptions, all of which a chaotic dinner
party violates:

1. **"At most one acoustic source per correlated pair."** The 0.9-vs-0.5
   correlation separation (bleed vs. genuine double-talk) was derived for
   the two-source case: each mic dominated by its own wearer. With three
   conversations running, every mic carries a *mixture* — wearer + bleed
   from 2–3 other speakers + diffuse babble. Pairwise correlation of two
   mixtures lands in the ambiguous middle (~0.4–0.7): bleed slips through
   as "genuine double-talk," and a genuinely-speaking quiet channel can be
   suppressed because it correlates with a louder mixture that merely
   *contains* the same third voice.
2. **"A buffer is homogeneous."** One decision per 200 ms means a buffer
   containing speaker 3's onset *and* speaker 1's tail is passed whole or
   muted whole. At high overlap rates, every buffer is heterogeneous.
3. **"Pass = clean."** The gate only ever passes or mutes; it never cleans.
   When speakers 1 and 3 talk simultaneously (correlation low → both pass,
   correctly), lane 3's session receives voice 3 *with voice 1 clearly
   audible underneath*. Whether the translate model transcribes the
   intrusion onto lane 3 is up to the model — we can't prompt it (no
   custom instructions on `gpt-realtime-translate`), only pick
   `near_field`/`far_field` noise reduction, which targets noise, not
   competing speech.

Secondary leaks that get worse at a party:

- **Hangover is a bleed window** (documented in the code): for 1.5 s after
  each genuine utterance, the channel passes *whatever arrives*, including
  another speaker's onset. At dinner-party turn rates, hangovers are
  nearly always live.
- **Pairwise winner-take-all is not transitive.** With channels 1–2
  correlated and 2–3 correlated but 1–3 not, suppression outcomes depend
  on pair evaluation order and can suppress two of three or oscillate.
  Real sources want *clustering*, not independent pair decisions.
- **Babble is speech.** Silero fires on background chatter (it is speech),
  so the burden of rejecting the diffuse party floor falls entirely on
  `minimumVoiceThreshold` — one global knob balancing quiet wearers
  against loud rooms.
- **Cost coupling:** every false gate-open opens/extends a paid session
  ($0.034/min). Better bleed rejection is directly cheaper.

The right mental model: today we have a **time-domain, full-band,
winner-take-all** separator with 200 ms resolution. Everything below is
about increasing its resolution (time, frequency) and moving from
*mute-the-loser* to *subtract-the-intruder*.

## 2. What we have to work with

Assets — this rig is unusually well-positioned for real separation:

- **Sample-synchronous channels.** All 4 channels arrive through one USB
  device (the RX), on one ADC/USB clock, deinterleaved float32 in the same
  buffer. Cross-channel DSP (masking, cancellation) is *possible at all*
  because of this; most multi-mic rigs (phones on a table) lack it.
- **A huge level prior.** The wearer's mouth is 15–25 cm from their lav;
  other speakers are 1–2.5 m away. Direct-path advantage ≈ 12–25 dB
  (reverb erodes the top of that range in a live room). This asymmetry is
  what makes the problem *much* easier than blind source separation: we
  never need to un-mix arbitrary sources, only suppress "content that is
  louder on someone else's mic."
- **Per-channel VAD already running** (pure-Swift Silero, 32 ms frames)
  — usable as adaptation control (see §3C) and already paying its compute.
- **vDSP/Accelerate in the toolbox** (`SignalAnalyzer` already does
  windowed FFTs); an STFT front-end is cheap and idiomatic here.
- **Latency headroom.** The gate is currently zero-latency, but nothing
  requires that: the API wants continuous 200 ms chunks and end-to-end is
  0.5–1.5 s. A fixed algorithmic latency of one STFT frame (~20–50 ms) is
  invisible. (A whole extra 200 ms lookahead buffer would even be
  tolerable if it bought accuracy.)
- **A live tuning bench.** The Signal tab already plots correlations and
  gate behavior against real audio and exports the window as JSON.

Liabilities — the things that quietly kill textbook solutions:

- **Per-TX clocks + radio link.** Each TX digitizes on its own crystal and
  the RX resamples each radio stream onto the USB clock. So the
  *inter-channel lag* (acoustic ~3 ms/m + radio 20–40 ms per link) is
  quasi-static but **drifts slowly and can step on radio re-sync**. Any
  phase-sensitive method must track delay; magnitude-domain methods don't
  care.
- **Per-TX onboard noise cancelling is nonlinear and time-varying.** DJI's
  NC (Basic/Strong) is a neural/spectral process applied *independently
  per TX before we ever see the samples*. Bleed of voice 1 on mic 3 has
  been chewed by TX3's NC differently than voice 1 on mic 1 by TX1's NC.
  This breaks the LTI assumption under adaptive cancellation (§3C) —
  possibly fatally — while magnitude masking (§3B) degrades gracefully.
  (Turning NC off changes the trade: cleaner linearity, more hiss and
  babble on every channel.)
- **Room reverb.** Dining-room RT60 ~0.4–0.8 s. The bleed path
  voice1→mic3 is a long, position-dependent impulse response that changes
  every time someone leans or gestures. Cancellation filters chase it;
  masks only see its magnitude envelope.
- **Compute/battery envelope.** iPad, Swift Playgrounds (no binary
  frameworks, no Core ML conversion workflow), battery already a concern
  (recent commits cut idle drain). Four channels of anything must fit
  beside 4 Silero instances on the audio queue.
- **No raw capture path today.** The Signal export carries 10 ms envelopes
  and gate telemetry — great for gate forensics, useless for prototyping
  separation algorithms offline. This is a real gap (see §5).

## 3. The option space

Ordered roughly by sophistication. These are not mutually exclusive — the
plausible end state is A + B with C as a measured, coherence-gated add-on.

### A. Smarter gating (same architecture, better decisions)

Cheap evolutions of the existing gate that don't clean audio but shrink
the failure windows:

- **Sub-buffer decisions.** Evaluate voicing + bleed per 32 ms VAD frame
  (Silero already frames at this rate internally) instead of per 200 ms
  buffer, and splice pass/silence transitions inside the buffer (with
  ~5 ms crossfades to avoid clicks). Directly addresses assumption 2 in
  §1; at dinner-party overlap rates this alone removes a lot of leaked
  onsets/tails.
- **Bleed-aware hangover.** During hangover, keep computing correlations;
  if the channel is currently losing a bleed pairing, the hangover must
  not pass audio (today suppression only wins over hangover within the
  same buffer decision; the leak is hangover-passes-while-unvoiced).
  Equivalently: hangover extends *the wearer's* speech, so it should be
  conditioned on "no other channel just became the winner of content
  correlated with mine."
- **Source clustering instead of pairwise winner-take-all.** Build the
  correlation graph over voiced channels each frame, take connected
  components (or complete-linkage clusters) as acoustic sources, pass one
  winner per cluster. Fixes non-transitivity; trivially cheap at N ≤ 4
  (≤ 6 pairs, already computed).
- **Learned per-pair bleed gains (the biggest gating win).** During
  single-talk intervals (only channel *i* voiced — the gate already knows
  this), measure the level ratio β_ij = RMS_j / RMS_i: "how loud does
  speaker *i* arrive on mic *j*." Slow-EMA it per ordered pair. Then a
  voicing decision on channel *j* can require
  `RMS_j > max_i(β_ij · RMS_i) · margin` — i.e. *"louder than the bleed
  that the currently-loud channels predict."* This is exactly the user's
  framing ("louder on 1's than 3's") turned into a calibrated, adaptive
  threshold rather than a fixed correlation cutoff. It also rescues the
  ambiguous-correlation regime: even when correlation is muddy, the level
  ledger still says whose voice it can't be. Robust, cheap (a few
  multiplies), and it feeds naturally into option B.

Ceiling of option A: it still never *cleans* a passed buffer. Simultaneous
speakers still cross-contaminate lanes. That requires B or C.

### B. Per-band masking in the STFT domain — the likely sweet spot

Generalize the gate's comparison from "one bin covering the whole 200 ms ×
full band" to **per time-frequency bin**:

1. STFT all active channels (e.g. 1024-sample Hann, 50 % overlap @ 48 kHz
   → ~21 ms frames, ~10 ms hop; or 512 @ 16 kHz on the VAD's resampled
   feed). `vDSP.FFT` is already in the codebase.
2. For each bin (f, t) on channel *j*, predict the bleed magnitude from
   every other channel using the learned per-pair, per-band gains from A:
   `B_j(f,t) = max_i β_ij(f) · |X_i(f,t)|`.
3. Attenuate bins the wearer doesn't dominate:
   `mask = |X_j|² / (|X_j|² + B_j²)` (a Wiener-shaped soft mask; a binary
   mask with a margin is the crude version), floor it at ~−15 dB rather
   than zero to avoid pumping artifacts.
4. Overlap-add back to time domain; the gate's session/cost logic then
   operates on the *cleaned* signal (a channel whose every bin got masked
   is silence — gating falls out for free).

Why this fits *this* problem unusually well:

- **It implements the ask.** Speaker 1's voice on mic 3 lives in bins
  where mic 1 is (calibratedly) louder → those bins get suppressed on
  lane 3 *while speaker 3's own bins pass*. Simultaneous independent
  speech on both lanes survives, each lane cleaned of the other. That is
  "remove speaker 1's voice from speaker 3's transmitter," achieved in
  the magnitude domain.
- **Speech is sparse in TF.** Concurrent talkers overlap surprisingly
  little at ~20 ms × ~50 Hz resolution (the W-disjoint orthogonality
  result behind DUET-family separation): most bins are dominated by one
  source, so per-bin winner-take-all recovers mostly-clean streams. Our
  level prior makes the per-bin decision far easier than DUET's blind
  case.
- **Immune to the liabilities that kill cancellation.** Uses magnitudes
  only → indifferent to inter-channel phase, TX clock drift, radio-lag
  steps, and (mostly) to DJI NC nonlinearity — NC changes magnitudes, but
  β is *learned from the NC-processed signals*, so it's baked in.
  Reverb blurs the mask, it doesn't break it.
- **The consumer is a machine.** Masking's classic cost is musical noise —
  offensive to human ears, largely shrugged off by ASR/translation
  models, especially with soft masks and an attenuation floor. Nobody
  listens to these streams; they get transcribed.
- **Compute is trivial.** 4 ch × ~100 FFTs/s × 1 k points is noise next
  to the four Silero instances already running. Latency: one frame
  (~21 ms) — well inside the headroom.

Honest limits:

- Bins where two voices genuinely collide get attenuated or passed dirty —
  masking cannot un-mix *within* a bin. At dinner-party overlap this is a
  minority of bins, and ASR rides through brief dropouts far better than
  through a competing intelligible voice.
- β_ij needs single-talk moments to learn and re-learn as people move.
  Dinner parties have plenty; cold start can seed from the worn-mic
  geometry prior (~−18 dB flat) and refine.
- Diffuse babble from people *not wearing mics* is invisible to the
  cross-channel ledger (no reference mic hears it "loudest"). Masking
  won't remove it — that stays the job of `minimumVoiceThreshold`, TX NC,
  and the server-side noise reduction. (A fifth "room reference" channel
  would change this; see §6.)

### C. Adaptive linear cancellation — the literal "subtract voice 1 from mic 3"

The textbook answer to the user's question: treat mic 1 as a *reference*
and adaptively estimate the transfer function ĥ (voice1-as-heard-on-mic1 →
voice1-as-heard-on-mic3), then subtract `ĥ * x₁` from mic 3 — the same
machinery as acoustic echo cancellation, with mic 1 playing the far-end
role. Sample-synchronous capture makes it *thinkable*; four things make it
fragile precisely at a chaotic dinner:

1. **The reference is dirty.** AEC's reference is a clean digital signal.
   Mic 1 contains speaker 3's bleed (and everyone else's). An adaptive
   canceller with a dirty reference *subtracts a filtered copy of speaker
   3's own voice from lane 3* — the classic target-leakage failure of
   adaptive noise cancellation. Mitigable (mask the reference first per B;
   only adapt when the ledger says the reference is single-talking) —
   the mitigations are exactly options A/B.
2. **Double-talk divergence.** Adapting while speaker 3 talks lets the
   filter model speaker 3 and cancel them. Standard practice freezes
   adaptation during double-talk — but the whole point of the party
   scenario is that double-talk is the *steady state*, so the filter is
   almost always frozen and stale while the room geometry moves.
3. **Nonlinear, time-varying TX NC** (§2) means voice 1 on mic 3 is *not*
   a linear filtering of voice 1 on mic 1. An LTI canceller can only
   remove the coherent part. This must be measured (see §5): if
   mic1↔mic3 magnitude-squared coherence during clean single-talk is
   ≥ ~0.9 across the speech band, ~10 dB of cancellation is on the table;
   at ≤ ~0.7 the ceiling is ~3–5 dB — not worth the machinery over B.
   With NC off, coherence should rise; that trade (hiss + more babble vs.
   linearity) is itself a measurable.
4. **Cost & drift.** Reverb-length filters (≥ 100 ms) per *directed* pair:
   at 16 kHz time-domain NLMS that's ~50 M MAC/s per pair, ×12 directed
   pairs worst case — heavy but vDSP-feasible; block-frequency-domain
   (PBFDAF) cuts it ~10×. TX clock drift means the filter re-converges
   forever. All of it competes with battery goals.

Verdict: don't start here. If the coherence measurement comes back high,
the payoff is real — cancellation *cleans the very bins masking has to
sacrifice* — and the sane form is a **frequency-domain canceller gated by
A's single-talk ledger, running under B's mask** (cancel what's coherent,
mask what remains). If coherence is low, C is a dead end on this hardware
and we lose nothing by having done B first, since B is C's prerequisite
(clean references, adaptation control) anyway.

### D. Neural separation / personal voice extraction

The research-grade answer: per-channel *target-speaker extraction* — a
small causal net conditioned on a speaker embedding keeps only the
wearer's voice (personalized enhancement, e.g. pDCCRN/DTLN-class models,
Conv-TasNet-class separators). Would also eat non-mic'd-party babble,
which nothing above can.

Reality check for this codebase: models are 1–10 M params and ~0.1–1
GMAC/s *per channel*; ×4 channels, pure-Swift execution (the Silero port
precedent is 310 k params at 31 Hz — one to two orders of magnitude
lighter), no Core ML/ONNX escape hatch in Playgrounds, plus an enrollment
UX (each guest records 10 s of voice before dinner?). Battery cost lands
exactly where recent work cut drain. This is the long-term ceiling, not
the next step — and it becomes far more attractive if the app ever
graduates to a CI-built Xcode project where Core ML is available.

Server-side variant worth tracking: OpenAI exposing competing-speech
suppression or diarization on the translate endpoint would move this
whole problem off-device; the current `session.update` surface
(`near_field`/`far_field` only) doesn't offer it (docs/RESEARCH.md §4).

### E. Non-DSP complements (cheap, orthogonal, do regardless)

- **Transcript-level dedup.** Whatever slips through, duplicates surface
  as near-identical source-transcript segments on two lanes within a few
  seconds. Fuzzy-match (normalized hanzi edit distance over a sliding
  window), keep the lane whose audio was louder / whose translation came
  first, tag the other bubble as bleed (and suppress its playback lane).
  Doesn't save session cost, but it fixes the *user-visible* symptom and
  gives us a measurable bleed-through rate for free. Failure mode to
  design around: the translate model paraphrases, so match on source
  text, not translations.
- **Hardware posture for parties** (README already gestures at this):
  worn-mic mode + TX NC **Strong** (tuned to isolate the close wearer —
  at a party this is working *with* us), TX gain trimmed so wearers peak
  well below clip, mics clipped high on the chest. Every dB of acoustic
  isolation is a dB the DSP doesn't have to find. Worth an explicit
  "party mode" checklist in the README once tuning is validated.
- **A "party" tuning profile** (like the worn/ambient split): higher
  `minimumVoiceThreshold`, shorter hangover (0.8 s), higher VAD-on
  probability — accepting slightly choppier capture to keep the bleed
  windows small. Pure settings work, zero code risk.

## 4. How the options compose

```
            TX NC (hardware, per-mic)                    [E]
              │
   4ch sync'd USB capture (existing)
              │
   per-pair level ledger β_ij  ←— single-talk calibration [A]
              │
   STFT soft mask per channel (remove "louder elsewhere") [B]
              │
   (optional, coherence-permitting: linear canceller
    on masked references, adaptation gated by ledger)     [C]
              │
   VAD + gate on the *cleaned* signal — sub-buffer,
   cluster winners, bleed-aware hangover                  [A]
              │
   per-lane sessions → transcript dedup safety net        [E]
```

The dependency order is convenient: A's ledger is B's calibration; B's
cleaned signals are C's references; nothing in A/B/E is wasted if C never
happens; D replaces B/C wholesale if it ever becomes feasible.

## 5. What to measure before writing any DSP (the actual next steps)

The whole design hinges on four numbers nobody has measured on this
hardware. The Signal tab export answers (1) today; the TXs' own
timecode-synced internal recordings (see below) answer (2) and the
acoustic core of (3) with zero code; (4) and the delivered-path
confirmation of (3) need raw audio as the app receives it, which we
currently cannot capture. That tooling gap — a Diagnostics "field
recorder": tap → 4 × mono WAV (or one 4-ch WAV) to the Files app,
48 kHz × 4 ch × float32 ≈ 46 MB/min — is small, but build it only once
the internal-recording measurements say option C is worth pursuing.

**The TXs' own internal recordings — better than first assumed.**
Verified against the DJI Mic 3 FAQ and user manual (2026-07): the TXs
are not free-running recorders, and they capture more than one file.
Three facts change the measurement plan:

- **Timecode, RX-distributed, 0.5 ppm.** The RX generates timecode
  itself (Master Run mode, the default — no external TC box needed) and
  continuously distributes it to every linked TX; spec'd drift is
  0.5 ppm (< 1 frame per 24 h), and the TC is embedded in the internal
  recording files. So the four WAVs align to ~millisecond out of the box,
  and within any short analysis window (0.5–2 s) relative clock drift is
  sub-microsecond — negligible. Seed alignment from TC, refine to
  sub-sample per segment with cross-correlation on single-talk stretches,
  and **phase-sensitive cross-TX measurements are feasible** from
  internal recordings alone.
- **Dual-file recording answers the NC question by construction.** With
  File Option → Dual-File, each TX simultaneously stores the **original**
  (raw, pre-DSP, `orig` suffix) and the **edited** file (noise
  cancellation, low-cut, tone preset, adaptive gain applied, `edit`
  suffix), 32-bit float WAV, split every 30 min, ~21.5 h total capacity.
  `orig` pairs measure the pure *acoustic* mixing path (β and coherence
  uncontaminated by NC); `orig` vs `edit` on one TX measures exactly what
  NC does to bleed; `edit`-pair coherence upper-bounds the delivered-path
  coherence.
- **Group start from the RX.** Swipe up on the main RX home screen to
  start internal recording on all TXs at once (or enable Startup Auto
  Recording per TX). No per-mic fumbling at the table.

This upgrades the internal recordings from "ground truth only" to the
primary instrument for measurements (2) and the acoustic core of (3),
plus ground truth for scoring — all zero-code. The asymmetry is useful:
if `edit`-pair coherence is already low, option C is dead and we learned
it without building anything; only if it's high does the in-app recorder
become necessary, to confirm coherence survives the *delivered* path —
the radio link (compressed by default; the "Lossless Audio" option
removes the codec at the cost of range) and the RX's resampling onto the
USB clock — and to measure lag stability (4), which only exists on that
path. Masking (§3B) doesn't care about (4); only cancellation (§3C) does.

Next-dinner kit, app unchanged: firmware current on RX+TXs; RX timecode
Master Run, one frame rate everywhere; every TX set to Dual-File 32-bit
float via RX group settings; group-start recording at sit-down; one clap
near all mics anyway (verifies the TC chain end-to-end); Signal-tab
freeze + export during heavy overlap for (1).

1. **Correlation distribution at a real party** *(available now)*: freeze
   + export the Signal window during overlapping speech; check where
   voiced-pair correlations actually land. If they still bimodally split
   around 0.55, the current gate is mistuned, not misdesigned — cheap
   fix. If they smear into 0.4–0.7 (expected), that's the empirical
   mandate for §3A/B.
2. **The bleed gain β and its stability** *(needs raw capture)*: during
   single-talk, per-pair level ratios across frequency; how far they move
   as people shift. Decides mask margins and whether a flat prior
   suffices to cold-start.
3. **Cross-channel coherence during single-talk** *(needs raw capture)*:
   magnitude-squared coherence mic_i↔mic_j, with TX NC off/Basic/Strong.
   **This single number decides §3C** (≥ 0.9 → cancellation viable;
   ≤ 0.7 → drop C permanently on this hardware). Also directly reveals
   how nonlinear each NC mode is.
4. **Lag stability** *(needs raw capture)*: inter-channel delay over
   minutes (GCC-PHAT on single-talk stretches). Tells us whether ±25 ms
   is the right search window, whether delay drift would force C's
   filters to chase, and whether masking's frame size comfortably
   swallows the spread.

Then prototype offline: the captured 4-channel WAVs + a Python notebook
(STFT masking is ~50 lines of NumPy) let us A/B mask designs against real
dinner audio — and, decisively, feed masked vs. raw audio through the
actual translate API and count **contamination** (words on the wrong
lane), **duplicates**, and **deletions** (wearer words lost). Those three
rates — not SNR — are the product metrics, and E's transcript dedup gives
us the duplicate counter to run continuously in the field.

## 6. Open questions

- Does `gpt-realtime-translate` actually transcribe audible-but-quieter
  competing speech, or does its front-end already suppress it? (If the
  model largely ignores −15 dB bleed, B's mask floor can be shallow and
  the urgency drops; measurable with the API harness above.)
- Where does the party babble floor sit relative to wearers after TX NC
  Strong? (Decides how much of the problem is mic'd-speaker bleed —
  solvable here — vs. unmic'd babble, which only D or hardware touches.)
- Is a fifth "room reference" input ever available? (A 5th TX as a table
  mic in M-mode isn't — the RX caps at 4 TXs — but if the dual-input
  probe (README) ever proves AirPods-mic-beside-USB, the AirPods feed
  could serve as a babble reference for subtracting *unmic'd* speech —
  the one hole in the cross-channel ledger.)
- Mask resynthesis vs. the VAD: Silero should see the *masked* signal
  (else it keeps voicing on bleed the mask already removed), which means
  moving the VAD behind the STFT and eating the frame latency there too —
  fine on paper, worth confirming the port's 16 kHz feed can be driven
  from overlap-added output without re-resampling artifacts.
- Where does per-bin masking run relative to the resamplers? (Masking at
  48 kHz pre-resample keeps one code path; masking on the 16 kHz VAD feed
  and applying decisions at 48 kHz halves FFT cost but splits domains.)
  An implementation detail, but it decides where the module boundary
  lands relative to `StreamResampler`.
