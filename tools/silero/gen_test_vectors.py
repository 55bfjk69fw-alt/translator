"""Generate test vectors for the Swift Silero VAD port.

Outputs:
  vectors_model.bin  -- 16 kHz frames + expected probs from onnxruntime
                        (u32 count, then per frame: 512 f32 samples, 1 f32 prob)
  vectors_stream.bin -- 48 kHz stream + expected per-frame probs where the
                        reference applies the SAME FIR decimator as Swift
                        (u32 sampleCount, samples f32..., u32 probCount, probs f32...)
"""
import struct
import wave
import numpy as np
import onnxruntime as ort

sess = ort.InferenceSession('silero_vad.onnx', providers=['CPUExecutionProvider'])
SR = np.array(16000, dtype=np.int64)

def run_stream_16k(audio):
    """Official wrapper semantics: 512-sample chunks, 64-sample context, carried state."""
    n = len(audio) // 512 * 512
    audio = audio[:n].astype(np.float32)
    state = np.zeros((2, 1, 128), dtype=np.float32)
    context = np.zeros(64, dtype=np.float32)
    probs = []
    for i in range(0, n, 512):
        chunk = audio[i:i + 512]
        x = np.concatenate([context, chunk])[None, :]
        out, state = sess.run(None, {'input': x, 'state': state, 'sr': SR})
        probs.append(float(out[0, 0]))
        context = chunk[-64:]
    return np.array(probs, dtype=np.float32)

# ----------------------------------------------------------- load real speech
with wave.open('en_speech.wav', 'rb') as w:
    assert w.getsampwidth() == 2, w.getsampwidth()
    wav_sr = w.getframerate()
    raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    if w.getnchannels() == 2:
        raw = raw[::2]
speech = (raw / 32768.0).astype(np.float32)
print(f"speech: {len(speech)} samples @ {wav_sr} Hz ({len(speech)/wav_sr:.1f}s)")
assert wav_sr == 16000

rng = np.random.default_rng(7)
# 16 kHz composite: silence | speech | noise | quiet speech | harsh noise
quiet_speech = 0.15 * speech[16000 * 10:16000 * 20]
composite16 = np.concatenate([
    np.zeros(16000 * 2, dtype=np.float32),
    speech[:16000 * 20],
    rng.normal(0, 0.03, 16000 * 4).astype(np.float32),
    quiet_speech,
    rng.uniform(-0.5, 0.5, 16000 * 2).astype(np.float32) * np.sin(np.arange(16000*2) * 0.001).astype(np.float32),
]).astype(np.float32)

probs16 = run_stream_16k(composite16)
n_frames = len(probs16)
with open('vectors_model.bin', 'wb') as f:
    f.write(struct.pack('<I', n_frames))
    for i in range(n_frames):
        f.write(composite16[i * 512:(i + 1) * 512].astype('<f4').tobytes())
        f.write(struct.pack('<f', probs16[i]))
print(f"vectors_model.bin: {n_frames} frames")

# ------------------------------------------------- 48 kHz pipeline reference
def design_fir(factor, taps=63, cutoff_norm=0.45):
    cutoff = cutoff_norm / factor
    mid = (taps - 1) / 2
    n = np.arange(taps)
    t = n - mid
    sinc = np.where(t == 0, 2 * cutoff, np.sin(2 * np.pi * cutoff * t) / (np.pi * t))
    window = 0.54 - 0.46 * np.cos(2 * np.pi * n / (taps - 1))
    k = (sinc * window).astype(np.float64)
    return (k / k.sum()).astype(np.float32)

def decimate_like_swift(x, factor):
    """Mirror of StreamingVAD.decimate: output at absolute input indices that are
    multiples of `factor` and >= taps-1."""
    fir = design_fir(factor)
    taps = len(fir)
    out = []
    for i in range(0, len(x), factor):
        if i >= taps - 1:
            seg = x[i - taps + 1:i + 1][::-1]
            out.append(np.dot(fir.astype(np.float64), seg.astype(np.float64)))
    return np.array(out, dtype=np.float32)

# Upsample composite16 to 48 kHz (linear interp is fine for a pipeline test:
# both pipelines see the identical 48 kHz signal).
t48 = np.arange(len(composite16) * 3) / 3.0
stream48 = np.interp(t48, np.arange(len(composite16)), composite16).astype(np.float32)

down16 = decimate_like_swift(stream48, 3)
probs_stream = run_stream_16k(down16)
with open('vectors_stream.bin', 'wb') as f:
    f.write(struct.pack('<I', len(stream48)))
    f.write(stream48.astype('<f4').tobytes())
    f.write(struct.pack('<I', len(probs_stream)))
    f.write(probs_stream.astype('<f4').tobytes())
print(f"vectors_stream.bin: {len(stream48)} samples -> {len(probs_stream)} frames")

# quick discrimination summary on the model vectors
sec = 16000 // 512
seg = {
    'silence  ': probs16[:2 * sec],
    'speech   ': probs16[2 * sec:22 * sec],
    'noise    ': probs16[22 * sec:26 * sec],
    'qt speech': probs16[26 * sec:36 * sec],
    'harsh    ': probs16[36 * sec:],
}
for name, p in seg.items():
    print(f"{name}: mean {p.mean():.3f}  p90 {np.percentile(p, 90):.3f}  frac>0.5 {(p > 0.5).mean():.2f}")
