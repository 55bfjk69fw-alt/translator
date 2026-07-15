# English pickup on Chinese lanes: never synthesize it (design)

Status: **layer 1 (script gate) + probe step implemented, 2026-07-15;
layer 2 (confidence floor) awaits the probe's field run** — see §4.2.
The gate lives in `CascadeLaneEngine.finishUtterance` /
`isPredominantlyLatin`; the probe step is CascadeProbe step 9.
Research date: 2026-07-15. Companion to `docs/CASCADE-PIPELINE.md` (the
cascade pipeline this modifies). Scope: the on-device cascade only — the
realtime OpenAI pipeline has its own (server-side) code-switching
behavior and is untouched.

## 1. The problem (field report, 2026-07-15)

Every cascade lane is a *Chinese* channel: one `SpeechTranscriber` locale
(`cascadeSourceLanguage`, default `zh-Hans`) fixed at Start for all mics,
zh→en `TranslationSession`, English `AVSpeechSynthesizer` out. When
English speech reaches one of those mics, the lane speaks gibberish:

- **F1 — the transcriber emits English text.** The zh-Hans model handles
  Mandarin–English code-switching, so sustained English often comes out
  as recognizable Latin-script words. That text then goes through the
  zh→en translator — a language pair it isn't (English is not Chinese) —
  and whatever comes back is synthesized. Best case the lane parrots the
  user's own English back at them; worst case it garbles it.
- **F2 — the transcriber force-decodes English audio into Mandarin.**
  A fixed-locale ASR model has no "not my language" output: English
  phonetics come out as phonetically-nearby Han characters. The text
  *looks* like Chinese, translates into fluent-looking nonsense, and is
  spoken with full confidence.

Triggers observed: a Chinese speaker switching to English mid-conversation
(legitimate gate-pass on their own mic — bleed rejection can't and
shouldn't catch it), and the user's English reaching a participant mic
(the user has no mic channel of their own — the reply flow is cue-card
based — so cross-channel bleed comparison has no reference to reject
against).

Desired behavior: **a Chinese lane never synthesizes speech for an
utterance that was actually English.** The listener is the English
speaker; they already heard it. Transcripts may keep it.

## 2. What the stack offers (research)

- **`SpeechTranscriber` is locale-fixed per instance.** No public
  per-result language tag, no supported zh+en dual-locale module, no
  acoustic language-ID API in the Speech framework. (iOS 26 docs +
  developer-forum threads; nothing found to the contrary.)
- **Per-run confidence exists but is opt-in.**
  `SpeechTranscriber.ResultAttributeOption.transcriptionConfidence`
  ("includes confidence attributes in a transcription's attributed
  string", Apple doc JSON) — requires constructing the transcriber with
  the explicit `init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
  instead of today's `preset: .progressiveTranscription`
  (`AnalyzerPool.makeSlot`). Whether F2 gibberish actually scores low is
  **UNVERIFIED** — no field reports found; needs the probe (§5).
- **`TranslationSession` has no same-language mode.** A zh→en session fed
  English input is out-of-contract; same-language pairings are rejected
  as unsupported at configuration time, and behavior on wrong-language
  *input* is undocumented (observed: pass-through or garble). No usable
  "this was already English" signal comes back.
- **The analyzer admission cap rules out a parallel English transcriber.**
  The target iPad admits ~3 concurrent analyses (CP0, CASCADE-PIPELINE
  §10); shadowing every lane with an en-US slot would halve the pool.
- **`NLLanguageRecognizer` adds nothing over script inspection here.**
  zh-Hans vs English is separable by Unicode script alone; the recognizer
  would only matter for Latin-vs-Latin pairs, and it too is blind to F2
  (gibberish Han *is* Chinese text).

## 3. Options considered

- **A. Script gate on the finalized source text** — classify each
  utterance's final text by Han-vs-Latin letter mass; English ⇒ skip
  MT + TTS. Catches F1 completely, deterministic, free, ~30 lines at one
  choke point. **Chosen (layer 1).**
- **B. Confidence floor** — request `.transcriptionConfidence`, suppress
  synthesis when an utterance's mean confidence is below a probed
  threshold. The only candidate signal for F2. Confidence distribution
  UNVERIFIED ⇒ probe before shipping. **Chosen (layer 2, gated on probe
  results).**
- **C. Parallel en transcriber / acoustic LID** — rejected: admission cap
  (above); no public acoustic LID.
- **D. Translation-result heuristics** (output ≈ input ⇒ was English) —
  rejected as primary: pays MT latency on the shared serialized
  translator before deciding, and F2 gives no stable signal. Subsumed
  by A for F1.
- **E. Locale switching / dual-locale module** — no supported API.

## 4. Recommended design

### 4.1 Layer 1 — script gate (ship now)

One choke point: `CascadeLaneEngine.finishUtterance` — both the settle
path and the sentence-ender sub-segment path already funnel through it,
after trimming and before `mtQueue.append`. Nothing volatile reaches TTS,
so gating finals is sufficient.

Classifier (pure function, engine-local):

- Count `han` = characters in the CJK Unified Ideographs blocks
  (U+3400–U+4DBF, U+4E00–U+9FFF); `latin` = Latin letters. Digits,
  punctuation, whitespace ignored.
- `han == 0 && latin >= 3` ⇒ English.
- Else English iff `latin / (latin + 2×han) ≥ 0.75` — the ×2 weight
  approximates per-word mass (one Han char ≈ one syllable; ~5 Latin
  letters ≈ one word), so "我们用 Zoom 开会" stays Chinese while one
  hallucinated 吗 at the end of an English sentence doesn't rescue it.
- Thresholds are named constants; expect one field-tuning pass.

On English verdict:

- Emit the source final as today (the transcript shows what was heard).
- Emit `.translationText(utterance:, text: <the recognized English>,
  isFinal: true)` — the text already *is* target-language, so the bubble
  closes reading sensibly instead of "—", and `setCascadeTranslation`
  needs no changes.
- Do **not** enqueue MT (junk jobs would delay real ones on the shared
  Apple session — and on the OpenAI MT stage (CASCADE-PIPELINE §14)
  would bill tokens for garbage and, on success, poison the shared
  context window with a non-Chinese "source") and therefore nothing
  reaches TTS.
- Log + count: `utterancesSuppressedEnglish` in `CascadeSnapshot`,
  rendered in the Diagnostics pipeline panel next to `audioSkips`.

No settings toggle: the suppressed output was never correct, and the
transcript keeps the evidence. (If a toggle is ever wanted, it slots into
Settings → Translation pipeline as a per-conversation-start read, like
`cascadeSpeechRate`.)

Known residue: an utterance that *starts* Chinese and switches to English
without a sentence ender closes as one mixed final; the ratio decides it
whole-utterance, so a dominant English tail costs the Chinese head its
synthesis (transcript keeps both). Acceptable — sub-segmentation on
sentence enders already splits most such turns.

### 4.2 Layer 2 — confidence floor (after the probe)

F2 text is indistinguishable from Chinese *as text*; per-run
`transcriptionConfidence` is the only on-device signal left. Plan:

1. Probe first (§5) — no pipeline change until the distributions are
   seen.
2. If separable: build pool transcribers with
   `attributeOptions: [.transcriptionConfidence]`, carry a mean
   confidence on `AnalyzerPool.ResultEvent`, and in `finishUtterance`
   suppress **TTS only** (keep source transcript AND translation, flagged
   in the log) below the floor. Conservative by construction: a
   misfired floor mutes one utterance's audio but never hides text.
3. If not separable: F2 stays open; revisit with a future
   OpenAI-STT stage provider (server models emit language tags), which
   the seam already anticipates.

## 5. Probe plan (extends CascadeProbe)

Implemented as probe step 9 (`step9EnglishIntoZh`), reusing the render
harness: five English sentences synthesized via the best en voice plus
the step-2 Mandarin render as baseline, each sentence fed to its own
zh-Hans transcriber constructed with
`attributeOptions: [.transcriptionConfidence]` (the explicit init — the
`.progressiveTranscription` preset doesn't request attributes). Logged
per final: the text, the verdict of the *actual* lane gate
(`CascadeLaneEngine.isPredominantlyLatin`, not a copy), and the per-run
confidence min/mean. Two questions, one run: (a) what does zh-Hans STT
actually emit for sustained English on-device — Latin (F1) or Han (F2)?
(b) do F2 finals score separably below genuine-Mandarin finals? "ABSENT"
confidences mean the attribute isn't populated on-device and layer 2 is
off the table. Results land in the probe export for the decision log.
One caveat: the confidence-attribute *read* (`run.transcriptionConfidence`)
follows the documented run-attribute pattern but was written without a
compiler — per the probe file's charter, fix the exact name from
compiler evidence on-device if it disagrees.

## 6. Decision log

- 2026-07-15 — Suppress-at-finishUtterance chosen over gate-time or
  MT-time detection: it is the single shared choke point where final
  text exists and nothing downstream has been paid for yet.
- 2026-07-15 — Show the recognized English in the translation slot
  rather than "—": the bubble stays meaningful and the "—" affordance
  keeps meaning "translation failed", not "translation withheld".
- 2026-07-15 — No parallel English analyzer: admission cap (~3) is the
  pool's scarcest resource (CASCADE-PIPELINE §6.1.1).

## 7. Sources

- SpeechTranscriber.ResultAttributeOption.transcriptionConfidence —
  https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption
  (doc-JSON: "Includes confidence attributes in a transcription's
  attributed string")
- SpeechTranscriber explicit init with attributeOptions —
  https://developer.apple.com/documentation/speech/speechtranscriber
- TranslationSession same-language pairings unsupported —
  https://developer.apple.com/documentation/translation/translationsession
- WWDC25 session 277 (SpeechAnalyzer volatile/final results, attribute
  options) — https://developer.apple.com/videos/play/wwdc2025/277/
- Admission cap + finalize behavior: CP0/field results,
  `docs/CASCADE-PIPELINE.md` §10 and `AnalyzerPool.swift` header.
