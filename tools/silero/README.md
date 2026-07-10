# Silero VAD port tooling

`TranslatorApp.swiftpm/Audio/SileroVAD.swift` is a pure-Swift port of the
Silero VAD v5 model's 16 kHz path (MIT, © Silero Team,
https://github.com/snakers4/silero-vad). Swift Playgrounds can't link binary
frameworks, so neither ONNX Runtime nor a prebuilt Core ML pipeline is an
option; instead the network's forward pass is implemented directly in Swift
and the weights ship as a package resource
(`TranslatorApp.swiftpm/Resources/silero_vad_16k.svad`, ~1.2 MB).

These scripts produce that weight blob from the official model file and prove
the port faithful. They run on any Linux/macOS box with Python 3.10+ — none
of this is needed on the iPad, only when regenerating or re-verifying the
weights (e.g. after a Silero release).

## Regenerating / re-verifying

```bash
pip install numpy onnx onnxruntime
curl -LO https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx
# v5 file used for the committed blob:
# sha256 1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3

# 1. Extract the 16 kHz-branch weights into silero_vad_16k.svad and verify a
#    numpy reimplementation of the graph against onnxruntime (~1e-6).
python3 extract_and_verify.py

# 2. Build test vectors from real speech (16 kHz frames + expected
#    probabilities, and a 48 kHz stream for the decimator + model pipeline).
curl -Lo en_speech.wav https://models.silero.ai/vad_models/en.wav
python3 gen_test_vectors.py

# 3. Compile the app's actual Swift source against the vectors and check it
#    reproduces onnxruntime's probabilities.
swiftc -O -o verify ../../TranslatorApp.swiftpm/Audio/SileroVAD.swift verify_harness.swift
./verify .
```

Last verified (2026-07): model-level max probability difference 1.6e-6 over
1187 frames of speech/noise/silence with carried LSTM state; full 48 kHz
pipeline (FIR decimator + re-blocking + model) 1.8e-6.

Performance note: Swift Playgrounds builds apps at -Onone, so SileroVAD.swift
keeps its hot path out of interpreted Swift — flat manually-managed buffers,
zero per-frame allocation, and all matrix work behind one gemv wrapper that
uses Accelerate BLAS on device. Measured single-threaded, per channel:
~12× realtime worst case (-Onone, no BLAS — the portable fallback), ~287×
realtime with -Onone glue + optimized BLAS (device-like; measured against
OpenBLAS, which also exercises the exact cblas_sgemv calls used on device).

## Weight blob format (`.svad`, version 1)

Little-endian: magic `SVAD`, u32 version, u32 tensor count, then per tensor:
u8 name length, UTF-8 name, u8 rank, u32 dims…, float32 data. Tensor names
and shapes match the ONNX 16 kHz branch (see `extract_and_verify.py`).

The model weights are redistributed under the MIT license — see
`SILERO_LICENSE`.
