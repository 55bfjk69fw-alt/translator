# Reply flow — push-to-talk teardown + reply prompter

> **Status (2026-07-11):** P1–P3 implemented (`Assist/`, ConversationView
> assist bar, Settings § Reply prompter, PTT removed). P4 awaits the
> dual-input probe verdict.

Design for replacing the push-to-talk return channel with a silent,
suggestion-driven reply flow. The user hears the table in English through
AirPods (unchanged), and **speaks all replies aloud in Mandarin themselves**,
reading from cue cards the app composes. No audio playback of replies, no TTS,
no input-route switching — the reply path never touches the audio pipeline.

Field-tested context this design responds to (big-group dinner, 2026-07):
push-to-talk went unused — holding a button, going deaf on the table for the
duration, and playing a robot voice were each individually disqualifying. The
user speaks some Mandarin and reads pinyin comfortably; what was missing was
*what to say*, fast, in a chaotic multi-thread conversation.

## 1. Goals / non-goals

Goals

- Tear out push-to-talk entirely (mode, UI, audio-session dance).
- A composer: type English → cue card with 汉字 + tone-marked pinyin + literal
  back-translation, sized to read aloud.
- A prompter: an agentic loop that watches the transcript and keeps 2–3
  candidate contributions ready, personalized by a user bio and a per-session
  context line, calibrated to the user's Mandarin level.
- Thread-scoped replies: pick a specific utterance and get suggestions for
  *that* exchange (the chaos-of-multiple-conversations mitigation).
- "I said this": one tap records a spoken cue card into the transcript as the
  user's turn — ground truth for the prompter without any microphone on the
  user.

Non-goals

- No audio playback of the user's replies (owner decision: their own voice,
  always).
- No AirPods-mic capture in this phase — pending the dual-input probe result;
  the design works identically with or without it (§8).
- No changes to the listening pipeline (gate, lanes, sessions).

## 2. UX

### Conversation tab

The PTT bar at the bottom is replaced by an **assist bar**:

```
┌────────────────────────────────────────────────────┐
│ transcript (unchanged)                             │
├────────────────────────────────────────────────────┤
│ [scene: 晚饭 w/ wife's family ✎]  [suggest now ↻]  │  ← context row
│ ‹ chip: Ask how long the drive was › ‹ chip: … ›   │  ← suggestion tray
│ [ compose a reply…                          ] [→]  │  ← composer
└────────────────────────────────────────────────────┘
```

- **Suggestion tray**: chips in a wrapping flow (no horizontal scrolling —
  every chip visible at a glance), each a short English gloss labeled with
  the thread it targets ("→ Auntie"). Unpinned chips are ordered by the
  model's `fit` score — most natural thing to say right now first — and
  every refresh re-scores carried-over chips too, so a chip drifts right
  as the conversation moves past its moment and truncation drops the
  least natural. Pins stay leftmost regardless.
- **Tap a chip → cue card** (sheet on iPhone, popover/inline expansion on
  iPad):

  ```
  Ask how long the drive was      ← gloss (intent), small anchor
  你们开了多久的车？             ← .largeTitle, the thing to read
  Nǐmen kāi le duō jiǔ de chē?   ← .title2, teal, the pronunciation aid
  "How long did you all drive?"   ← meaning: LITERAL translation of the line
  casual · replies to Uncle Wang  ← register + target
  [ I said this ]  [ Refine… ]    ← actions
  ```

  **I said this** appends the utterance to the transcript on the user lane
  (final immediately) and dismisses. **Refine** drops the gloss into the
  composer for editing. Dismissing does nothing — unspoken cards never
  pollute the transcript.
- **Composer**: free text (English, or mixed — the model handles it) →
  same cue card. This is the escape hatch when no suggestion fits.
- **Long-press any transcript bubble** → context menu:
  - *Reply to this* — scoped suggestion request for that utterance/thread.
  - *Explain this* — idiom/nuance breakdown of that bubble (same client, a
    different task prompt; rendered as a card, never enters the transcript).
- **Scene chip**: the per-session context one-liner ("dinner in Chengdu with
  the in-laws; we just got back from Jiuzhaigou"), editable in place. This is
  deliberately in the Conversation tab, not Settings — it changes every meal.

Suggestion tray placement is the same in portrait and landscape for phase 1;
a right-hand column on iPad landscape is a later polish item, not structure.

### Settings

New **"About you (reply prompter)"** section:

| Setting | Type | Default | Notes |
|---|---|---|---|
| Enable prompter | toggle | on | Off = composer still works (compose calls only) |
| Bio | multi-line text | "" | Who you are, relationship to the group, safe topics |
| Mandarin level | picker | elementary | beginner / elementary / intermediate / advanced — caps sentence length & vocabulary in the prompt |
| Tone | picker | auto | casual / polite / auto (model reads the room) |
| Suggestions in tray | picker | 10 | Caps UNPINNED chips only — pins never count. Each batch requests up to `min(limit, 8)` suggestions, so the ask scales with the limit |
| Refresh rate limit | picker | 3 s | Minimum gap between ambient requests (0–8 s; 0 = one-in-flight is the only throttle). Applies live mid-conversation |
| Priority processing | toggle | off | `service_tier: "priority"` — faster/more consistent TTFT at ~2× token price |
| Auto-suggest | toggle | on | Off = tray fills only via "suggest now" / scoped requests |
| Model | picker | `gpt-5-mini` | Populated from the account's `/v1/models` (chat-capable ids only), static fallback list offline; `reasoning_effort: low` is pinned for reasoning models |

`userName` already exists and is reused. Reply language stays a setting
(`pttOutputLanguage` renamed → `replyLanguage`, default `zh`) so the flow
generalizes beyond Mandarin.

## 3. Architecture

Three new files, no changes to the audio stack:

```
Assist/AssistEngine.swift        — ObservableObject: triggers, debounce,
                                   in-flight management, suggestion state
Assist/ChatCompletionClient.swift — minimal URLSession client for
                                   POST /v1/chat/completions, structured output
Assist/AssistPrompt.swift        — prompt + JSON-schema builders for the
                                   four tasks: suggest / scoped-reply /
                                   compose / explain
```

Integration points in existing code:

- `AppModel`'s 1 Hz timer already calls `transcript.finalizeStale` — after it,
  notify `AssistEngine` of newly-finalized utterances (engine holds a weak
  transcript reference and a high-water mark; no TranscriptStore changes for
  reads).
- `TranscriptStore` gains one small API:
  `addUserUtterance(source:gloss:)` — appends a final utterance on
  `SpeakerLane.userLaneID` (hanzi as `sourceText`, gloss as `translatedText`)
  so user turns render exactly like everyone else's bubbles, pinyin included,
  via the existing `UtteranceBubble`.
- `ConversationView` swaps `pttBar` for the assist bar + cue-card
  presentation.
- API key comes from the existing `KeychainStore`; no second credential.

### Trigger logic (the "agentic loop")

Designed for the worst case the app exists for: several conversations
running simultaneously across four lanes, where a global lull may never
arrive.

- **Ambient trigger — rate-limited immediate fire.** A finalization OR a
  sentence boundary streaming in mid-utterance (。？！.?! landing in a
  source/translation delta) fires a request *immediately* unless a request
  was made within the rate limit (Settings, default 3 s, 0 = fire the
  moment the previous request returns); otherwise one fire is scheduled
  for the boundary (further triggers fold into it). Sentence-boundary firing means
  chips can land while the speaker is still mid-utterance — the window
  includes open utterances marked "[mid-speech]", and the system prompt
  warns the model that all lines are error-prone speech-to-text. Turn-taking conversation → chips land ~3–4 s after someone stops
  talking (the ~2.5 s the transcript itself needs to finalize, plus the model
  call — no artificial wait). Continuous multi-thread chatter → a steady
  ~5 s cadence by construction, no starvation possible. Quiet table → no
  finalizations, no calls, no cost. There is deliberately no debounce: its
  only benefit was saving calls that cost fractions of a cent, and it bought
  that with seconds of latency at exactly the moments the tray should feel
  live.
- Fires only if auto-suggest is on and there is new content since the last
  batch.
- **One request in flight, ever; responses are shown, not discarded.** A
  response that arrives after newer speech finalized is still applied — it
  is one or two utterances behind, and carry-over keeps it coherent — and
  the newer content immediately schedules the next fire. The only responses
  dropped outright are ambient batches superseded by a manual/scoped
  request. No queues.
- If the ~2.5 s finalization delay itself proves to be the bottleneck in the
  field, the escape hatch is triggering on source-stream quiet instead of
  full finalization (translation trails source; suggestions only need the
  source text) — noted here, not built until real use demands it.
- **Scoped/compose/explain requests** fire immediately and pre-empt the
  ambient loop (its next batch just comes later).
- **Failure**: log to Diagnostics, show a subtle "prompter offline" chip in
  the tray, retry the *next* trigger (no retry storms). Errors never block
  the transcript or listening pipeline.

### Tray stability under chaos

A steady ~5 s replace cadence would make chips churn faster than anyone can
read at a loud table. Three mechanisms keep the tray calm:

- **Carry-over, not just replace**: each ambient request includes the current
  tray (id + gloss + reply_to). The model returns the new set with a `keep`
  id where an existing chip is still the right suggestion — kept chips stay
  in place untouched, so a chip only moves or vanishes when the conversation
  actually moved past it. Pinned chips are never dropped regardless.
- **Engagement bias**: the prompt tells the model which thread the user most
  recently engaged with ("I said this" / scoped replies are the signal) and
  asks for suggestions biased to that thread, plus at most one option from
  elsewhere at the table. Chaos becomes: *your* conversation dominates the
  tray, with one "join the other thread" escape hatch.
- **Pinning + `reply_to` labels** (already decided): pins survive any batch,
  and every chip names its target, so grabbing the right thread is a glance,
  not a read.

### Request shape

One `chat/completions` call, `response_format: json_schema (strict)`:

```json
{
  "suggestions": [
    {
      "keep":     "b3",
      "gloss":    "Ask how long the drive from Chongqing was",
      "meaning":  "How long did you drive from Chongqing?",
      "hanzi":    "你们从重庆开了多久的车？",
      "pinyin":   "Nǐmen cóng Chóngqìng kāi le duō jiǔ de chē?",
      "register": "casual",
      "reply_to": "Uncle Wang",
      "fit":      85
    }
  ]
}
```

`keep` (nullable) points at a current-tray chip id when the entry is that
chip carried over — the tray leaves it in place instead of animating a
replacement. The request includes the current tray (id, gloss, reply_to,
pinned flag) so the model can make that call.

System prompt contract (assembled by `AssistPrompt`):

- Persona: the user's name, bio, Mandarin level, tone preference, scene line.
- Level calibration: hard caps per level (beginner ≤ 8 chars & top-1k vocab;
  elementary ≤ 14 chars; …) — the suggestions must be *sayable*, not elegant.
- Task: read the recent conversation (last ~20 finalized utterances, speaker
  names attached, user turns marked as such), identify the active threads,
  and propose 2–3 contributions the user could *say out loud right now* —
  a mix of "join the main thread" and "react to what was just said".
  `reply_to` names the speaker/thread each targets, or `"table"`.
- Pinyin must be tone-marked. (Fallback: if the model omits it, derive via
  the existing ICU `String.pinyin` transform.)

Compose variant: same contract, input is the user's draft, output is exactly
one suggestion. Explain variant: input is one utterance, output is
`{explanation, key_phrases: [{hanzi, pinyin, meaning}]}` — rendered, never
stored.

### Latency levers (2026-07 research)

Applied, in order of impact: reasoning effort pinned to the per-family
FLOOR (`none` on gpt-5.1+, where the model behaves as non-reasoning;
`minimal` on the gpt-5 family; `low` on o-series — `gpt-5-chat-*` reject
the parameter); `verbosity: low` on the gpt-5 family to trim output
tokens; optional `service_tier: "priority"` toggle. Free structural win
already in place: the static system prompt (persona/rules/bio/scene)
leads every request, so OpenAI's automatic prompt caching hits it —
cached-prefix requests are faster and input-discounted. Next lever if
ever needed: streaming with incremental JSON parsing so chips render as
they generate.

### Cost & model

~1.5k tokens in / ~600 out per call. Worst case scales with the rate-limit
setting: at the 3 s default, continuous chatter is ~1,200 calls/hour —
roughly $2–3/hour at `gpt-5-mini` pricing; at 0 the request round-trip
itself (~2–3 s) is the pace. Still small against the ~$10/hour realtime
sessions, and typical turn-taking conversation costs a fraction of it. Token usage per call is logged
to Diagnostics (no UI meter for now). The model field is a Settings
escape-hatch, same philosophy as the realtime model/endpoint fields.

## 4. Push-to-talk teardown

Removed outright:

- `AppModel`: `Mode.pushToTalk`, `pttPressed/pttReleased`, `pttEngaged` +
  lock, `pttLevel`, the PTT branch in `installInputHandler`,
  `processPTTBuffer`, the user-lane branch of `closeIdleSessions`,
  `handleChineseAudio`, `playChineseOverSpeaker`, `playUtteranceAudio`,
  `speakerOverrideActive`, `zhPlaybackLane` (player count drops to 4).
- `AudioSessionController.configureForPushToTalk`, `overrideToSpeaker`.
- `ConversationView`: `pttBar`, `PushToTalkButton`, play buttons on bubbles.
- `TranscriptStore`: `translatedAudio`, `appendTranslatedAudio`, the `.audio`
  stream case, `maxStoredAudioUtterances`.
- `AppSettings`/`SettingsView`: `autoPlayChinese` + its section; the
  "My speech translates to" picker moves under the prompter section as
  "Reply language" (`pttOutputLanguage` key renamed with migration).
- README: PTT hardware notes, usage step 4, HFP troubleshooting entry
  (rewritten — HFP can now only be entered by the probe), roadmap item on
  PTT recording quality (superseded by the probe).

Kept deliberately:

- `SpeakerLane.userLaneID` and the user lane — now fed by "I said this"
  (and, probe-permitting, the personal capture lane later).
- The indigo user-bubble styling and pinyin rendering — cue cards and user
  turns reuse it.

## 5. Threading & chaos handling

Two mechanisms, both cheap:

1. The ambient prompt asks the model to cluster recent utterances into
   threads and label every suggestion with `reply_to`. The tray shows the
   label; the user picks the thread by picking the chip.
2. Long-press → *Reply to this* pins the next batch to one utterance. This
   turns table chaos from a problem into a targeting gesture.

No client-side diarization/topic tracking — the transcript window plus the
model is the thread tracker. If context windows get tight at 400 utterances,
the serializer truncates by *thread recency*, not raw count (utterances from
threads active in the last 2 minutes first).

## 6. Privacy note

The transcript already transits OpenAI via the realtime sessions; the
prompter sends the same content plus the bio to the same vendor under the
same key. The bio should carry nothing the user wouldn't say at the table —
the Settings footer says exactly that.

## 7. Phasing

- **P1 — teardown + composer**: remove PTT (§4), assist bar with composer
  only, `ChatCompletionClient`, cue cards, "I said this", bio/level/tone
  settings. Independently shippable; already a strictly better reply flow.
- **P2 — ambient prompter**: `AssistEngine` loop, suggestion tray, scene
  chip, "suggest now".
- **P3 — scoped actions**: long-press *Reply to this* / *Explain this*.
- **P4 — probe-contingent personal lane** (§8).

## 8. Dual-input probe contingency

If the Diagnostics probe (see RESEARCH.md §2) proves AirPods-mic capture can
run beside USB, add a **personal lane**: AirPods mic → resampler → one more
translation session, transcribing the user's spoken Mandarin onto the user
lane like any speaker. It *supplements* "I said this" (which stays the
authoritative record of cue-card turns — learner-accented Mandarin
transcribes unreliably) and gives the prompter the user's off-script turns
too. `AssistEngine` reads the transcript only, so it is indifferent to where
user turns come from — this phase bolts on without touching P1–P3 code.

If the probe fails, P4 is simply dropped; nothing else changes.

## 9. Resolved design decisions (owner, 2026-07-11)

1. **Chips never skip the cue card.** The card is the pronunciation aid;
   recording "I said this" always goes through it, no shortcut even for
   repeated phrases.
2. **Tray refresh: replace-on-new-batch, with pinning.** Each new batch
   replaces the tray (never while it's being touched); long-press a chip to
   pin it — pinned chips survive batch replacement, sit leftmost, and are
   unpinned by another long-press or by being said. Pins are the "save this
   for the right lull in the conversation" mechanism.
3. **Explain this = nuance + key phrases.** A short meaning/idiom
   explanation plus 2–3 key phrases (hanzi, pinyin, meaning). No word-by-word
   breakdown — this is a dinner-table tool, not a flashcard generator.
4. **Tray limit is configurable and excludes pins** (owner, post-field-test):
   default 10 unpinned chips; pinned chips never count against or get
   truncated by the limit; the per-batch request size scales with the limit
   (`min(limit, 8)` ambient, `min(limit/2, 5)` scoped) so a bigger tray
   actually fills.
