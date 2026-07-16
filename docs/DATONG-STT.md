# Datong-dialect STT research (2026-07-15)

Provider evaluation for recognizing 大同话 / 晋北方言 (Northern Jin,
Datong–Baotou 大包片 subgroup of Jin Chinese 晋语) in the cascade
pipeline's STT stage. Companion to `docs/CASCADE-PIPELINE.md` (the seam
this plugs into, §5.2/§6.1.1). Confidence flags follow that doc's
conventions.

## 1. Problem statement

The cascade pipeline's shipped STT stage is Apple
`SpeechAnalyzer`/`SpeechTranscriber` with the `zh_CN` locale. That model
is standard-Mandarin: Datong-*accented* Mandarin mostly works; genuine
晋北 dialect speech (entering tones 入声, 分音词, dialect lexicon) does
not, and no Apple locale covers any Jin variety. The CP4-planned OpenAI
STT provider makes no Chinese-dialect claims either. So dialect coverage
requires a third-party provider behind the STT seam.

No public Datong speech corpus exists (checked Hugging Face datasets,
2026-07-15) — fine-tuning would require self-collected audio. The only
published Datong-specific work is a 2020 attention-based speech
translation paper from North University of China with no released
weights.

## 2. Provider evaluation

Summary (per active lane; realtime-pipeline anchor is $3.05/hr —
`RealtimeLaneEngine.combinedDollarsPerSessionMinute`):

| Provider | 晋北/大同 claim | Cost class | Streaming | Verdict |
| --- | --- | --- | --- | --- |
| Alibaba Fun-ASR-Realtime (Bailian) | 晋语 explicit, subgroup unstated | ~¥0.6–1/hr (verify in console) | yes, first char ~100 ms class | **build first** |
| iFlytek 方言识别大模型 | strongest: 202 dialects, all 288 prefecture cities (Datong is one) | ¥88 promo = 100k utterances; list via quote | yes (`dwa` partials) | escalation if Fun-ASR's Jin is Taiyuan-flavored |
| Self-hosted Fun-ASR-Nano (Apache-2.0, 800M) | Jin in training set; smaller model, lower accuracy | hardware only | **no partials** (utterance-level) | reserve; only path to fine-tuning |
| Volcengine Doubao | none — 8 Mandarin supergroups + 11 dialects, no Jin | ¥500–1500/concurrent/mo | yes | ruled out |
| Tencent Cloud ASR | no explicit Jin claim found | — | yes | not pursued |
| OpenAI STT (CP4 plan) | none | — | yes | doesn't solve dialect |
| Apple `zh_CN` (shipped) | none | $0 | volatile results | stays as fallback |

### 2.1 Alibaba Fun-ASR-Realtime — selected

- Model `fun-asr-realtime` (snapshot `fun-asr-realtime-2025-11-07`) on
  Bailian / Model Studio. Docs list 普通话、粤语、吴语、闽南语、客家话、
  赣语、湘语、**晋语** + 26 regional accents.
  ([model docs](https://help.aliyun.com/zh/model-studio/asr-model/))
  Confidence: high.
- 2026-07-06 upgrade: one model, 30 languages + 16 dialects across all
  eight dialect regions; avg character accuracy 88.62% on the 16-dialect
  bench, leading 12 categories (vendor bench — beat Volcengine/Tencent);
  first-character latency "hundred-millisecond level"; streaming accuracy
  close to offline. ([IT之家](https://www.ithome.com/0/973/062.htm))
  Confidence: medium (vendor-published).
- **晋语 is claimed at the dialect-group level only.** Whether training
  skews 并州片 (Taiyuan) vs 大包片 (Datong) is unknowable from docs —
  UNVERIFIED, must bench with real 大同话 audio (§3).
- Protocol: WebSocket, arbitrary sample rate, formats pcm/wav/mp3/opus/
  speex/aac/amr; intermediate (partial) results supported. Maps cleanly
  onto the pool verb surface (`acquire → feed → finishAndRetire`) and the
  `ResultEvent {text, isFinal}` replace-in-place contract.
- Pricing: per second of audio, billed only while in use; exact 元/秒 not
  on public doc pages (console shows it); discounted 语音转写资源包 exist
  (~¥0.6/hr class was referenced in promos). UNVERIFIED — owner is
  confirming list price with Alibaba contacts; cost plumbing ships with
  the rate left nil (no dollars reported) until confirmed.
- Account: owner has one. If it is a mainland Bailian account the CN
  endpoint applies; the international (Singapore) Model Studio also
  documents fun-asr — whether the dialect-capable snapshot is served
  there is UNVERIFIED. From outside China expect +200–400 ms RTT to the
  CN endpoint.

### 2.2 iFlytek 方言识别大模型

- Only vendor claim specific enough to cover Datong: 202 dialects across
  all 288 prefecture-level cities, automatic dialect identification with
  no language parameter (handles 大同话↔普通话 code-switching by design).
  ([IT之家](https://www.ithome.com/0/804/786.htm),
  [product page](https://www.xfyun.cn/services/dia_model)) The exact
  202-dialect list is a console-download Excel — confirm 大同 before
  committing. Confidence: high for the claim, medium for Datong
  specifically.
- API ([docs](https://www.xfyun.cn/doc/spark/spark_slm_iat.html)): WSS,
  16k/8k PCM16 mono, 1280 B frames at 40 ms pacing, partials via `dwa`,
  **60 s max per connection** (fine for VAD-bounded utterances; needs a
  rollover guard for monologues).
- Cost: free 50k-request trial; ¥88 new-customer pack = 100k
  interactions (one interaction ≈ one utterance connection ≈ fractions
  of a yuan per conversation-hour). List pricing by console quote.
- Friction: 3-credential HMAC-signed-URL auth, chattier framing,
  mainland-hosted endpoints, CN-verified account onboarding. Estimated
  ~30–50% more work than the Fun-ASR provider.

### 2.3 Self-hosted Fun-ASR-Nano / FunASR runtime

- [Fun-ASR-Nano-2512](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512)
  (800M, Apache-2.0) + [FunASR runtime](https://github.com/modelscope/FunASR)
  (WebSocket server / OpenAI-compatible HTTP). Request-response per
  utterance — the design doc's adapter pattern (§2.4) lifts it into the
  seam, but there are **no volatile partials** (bubble stays empty until
  utterance end).
- Unique advantages: free, offline-capable (LAN server + iPad), and the
  only path that improves with owner-collected 大同话 data (fine-tune).
- Kept in reserve; not the first build.

### 2.4 Ruled out

- **Volcengine Doubao**: dialect list is the eight Mandarin supergroups
  plus 11 dialects — Jin absent (Jin is classified outside Mandarin).
  ([docs](https://www.volcengine.com/docs/6561/109880)) Priciest model
  (concurrency-based).
- **Tencent Cloud ASR**: no explicit Jin claim found; Alibaba's bench
  claims to beat it on dialects. Not pursued.

## 3. Bench plan (before trusting any provider)

Record genuine 大同话 clips (not Datong-accented Mandarin), then compare
character accuracy across: Bailian file-recognition API (fun-asr),
iFlytek trial console, Fun-ASR-Nano HF Space, and the shipped Apple
`zh_CN` path as baseline. A few hours, zero integration code, settles
the 大包片-coverage question empirically. `CascadeProbe`/bench-mode is
the natural in-app home if this graduates from manual testing.

## 4. Decision (owner, 2026-07-15)

Build the **Alibaba Fun-ASR-Realtime** STT stage first, on top of the
cascade branch. **Implemented same day**: `Cascade/STTPool.swift` (the
extracted STT seam), `Cascade/FunASRPool.swift` (the provider), and the
Settings/AppModel wiring — design notes in `docs/CASCADE-PIPELINE.md`
§15. The per-second rate is left nil in `FunASRPool` until the list
price is confirmed; billed seconds are counted and logged regardless. iFlytek remains the escalation path for dialect
fidelity; self-hosting remains the fine-tuning path. Two follow-ups ride
on owner's Alibaba contacts: exact fun-asr-realtime list pricing, and
whether the dialect snapshot is served from the international endpoint.

Downstream caveat: dialect vocabulary that survives ASR normalization
hits the MT stage next — the cascade MT prompt's STT-provenance rules
(commit `1db777a`) are positioned for this; expect prompt iteration once
real dialect transcripts flow.
