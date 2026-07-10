"""Extract Silero VAD v5 16 kHz weights from the official ONNX file and verify
a from-scratch numpy reimplementation against onnxruntime.

Outputs:
  silero_vad_16k.svad  -- binary weight blob for the Swift port
"""
import struct
import numpy as np
import onnx
from onnx import numpy_helper
import onnxruntime as ort

MODEL = 'silero_vad.onnx'

# ---------------------------------------------------------------- extraction
m = onnx.load(MODEL)
ifnode = [n for n in m.graph.node if n.op_type == 'If'][0]
then = [a for a in ifnode.attribute if a.name == 'then_branch'][0].g

consts = {}
for n in then.node:
    if n.op_type == 'Constant':
        arr = numpy_helper.to_array(n.attribute[0].t)
        consts[n.output[0].replace('If_0_then_branch__Inline_0__', '')] = arr

WANTED = [
    'stft.forward_basis_buffer',       # (258, 1, 256)
    'encoder.0.reparam_conv.weight',   # (128, 129, 3)
    'encoder.0.reparam_conv.bias',
    'encoder.1.reparam_conv.weight',   # (64, 128, 3)
    'encoder.1.reparam_conv.bias',
    'encoder.2.reparam_conv.weight',   # (64, 64, 3)
    'encoder.2.reparam_conv.bias',
    'encoder.3.reparam_conv.weight',   # (128, 64, 3)
    'encoder.3.reparam_conv.bias',
    'decoder.rnn.weight_ih',           # (512, 128) pytorch gate order i,f,g,o
    'decoder.rnn.weight_hh',           # (512, 128)
    'decoder.rnn.bias_ih',             # (512,)
    'decoder.rnn.bias_hh',             # (512,)
    'decoder.decoder.2.weight',        # (1, 128, 1)
    'decoder.decoder.2.bias',          # (1,)
]
W = {k: consts[k].astype(np.float32) for k in WANTED}
for k in WANTED:
    print(f"{k:35s} {W[k].shape}")

# ------------------------------------------------------------- numpy forward
def conv1d(x, w, b, stride=1, pad=1):
    """x: (Cin, T); w: (Cout, Cin, K); zero padding both sides."""
    cin, t = x.shape
    cout, _, k = w.shape
    xp = np.zeros((cin, t + 2 * pad), dtype=np.float32)
    xp[:, pad:pad + t] = x
    tout = (t + 2 * pad - k) // stride + 1
    out = np.empty((cout, tout), dtype=np.float32)
    for o in range(tout):
        seg = xp[:, o * stride:o * stride + k]           # (Cin, K)
        out[:, o] = np.tensordot(w, seg, axes=([1, 2], [0, 1])) + b
    return out

def forward(x576, h, c):
    """x576: (576,) float32; h, c: (128,). Returns prob, h', c'."""
    # reflect-pad right by 64  (torch F.pad(x, (0, 64), 'reflect'))
    y = np.concatenate([x576, x576[-2:-66:-1]])          # (640,)
    # STFT as conv: kernel 256, stride 128 -> 4 frames, 258 channels
    basis = W['stft.forward_basis_buffer'][:, 0, :]      # (258, 256)
    frames = np.stack([y[i * 128:i * 128 + 256] for i in range(4)], axis=1)  # (256,4)
    spec = basis @ frames                                # (258, 4)
    mag = np.sqrt(spec[:129] ** 2 + spec[129:] ** 2)     # (129, 4)
    a = np.maximum(conv1d(mag, W['encoder.0.reparam_conv.weight'], W['encoder.0.reparam_conv.bias'], 1), 0)
    a = np.maximum(conv1d(a, W['encoder.1.reparam_conv.weight'], W['encoder.1.reparam_conv.bias'], 2), 0)
    a = np.maximum(conv1d(a, W['encoder.2.reparam_conv.weight'], W['encoder.2.reparam_conv.bias'], 2), 0)
    a = np.maximum(conv1d(a, W['encoder.3.reparam_conv.weight'], W['encoder.3.reparam_conv.bias'], 1), 0)
    xt = a[:, 0]                                         # (128,) single time step
    gates = W['decoder.rnn.weight_ih'] @ xt + W['decoder.rnn.bias_ih'] \
          + W['decoder.rnn.weight_hh'] @ h + W['decoder.rnn.bias_hh']
    sig = lambda v: 1.0 / (1.0 + np.exp(-v))
    i, f, g, o = gates[:128], gates[128:256], gates[256:384], gates[384:]
    c2 = sig(f) * c + sig(i) * np.tanh(g)
    h2 = sig(o) * np.tanh(c2)
    feat = np.maximum(h2, 0)
    logit = W['decoder.decoder.2.weight'][0, :, 0] @ feat + W['decoder.decoder.2.bias'][0]
    return float(sig(logit)), h2.astype(np.float32), c2.astype(np.float32)

# ------------------------------------------------------------- verification
sess = ort.InferenceSession(MODEL, providers=['CPUExecutionProvider'])
rng = np.random.default_rng(42)

# streaming test: 200 chunks with state carried, mixed content
chunks = []
for k in range(200):
    kind = k % 4
    if kind == 0:
        chunk = rng.normal(0, 0.05, 512)                      # noise
    elif kind == 1:
        t = np.arange(512) / 16000 + k * 0.032
        chunk = 0.3 * np.sin(2 * np.pi * 150 * t) * (1 + 0.5 * np.sin(2 * np.pi * 4 * t))
        chunk += 0.1 * np.sin(2 * np.pi * 450 * t) + 0.02 * rng.normal(0, 1, 512)  # speech-ish
    elif kind == 2:
        chunk = np.zeros(512)                                  # silence
    else:
        chunk = rng.uniform(-1, 1, 512)                        # harsh noise
    chunks.append(chunk.astype(np.float32))

state = np.zeros((2, 1, 128), dtype=np.float32)
context = np.zeros(64, dtype=np.float32)
h = np.zeros(128, dtype=np.float32)
c = np.zeros(128, dtype=np.float32)
sr = np.array(16000, dtype=np.int64)

max_dp = 0.0
max_ds = 0.0
for chunk in chunks:
    x = np.concatenate([context, chunk])
    out, state = sess.run(None, {'input': x[None, :], 'state': state, 'sr': sr})
    p_ref = float(out[0, 0])
    p_my, h, c = forward(x, h, c)
    max_dp = max(max_dp, abs(p_ref - p_my))
    max_ds = max(max_ds, float(np.max(np.abs(state[0, 0] - h))), float(np.max(np.abs(state[1, 0] - c))))
    context = chunk[-64:]

print(f"\nmax |prob diff|  = {max_dp:.3e}")
print(f"max |state diff| = {max_ds:.3e}")
assert max_dp < 1e-5 and max_ds < 1e-4, "MISMATCH"
print("numpy reference MATCHES onnxruntime")

# ------------------------------------------------------------------ export
def write_blob(path):
    with open(path, 'wb') as f:
        f.write(b'SVAD')
        f.write(struct.pack('<II', 1, len(WANTED)))
        for name in WANTED:
            arr = np.ascontiguousarray(W[name], dtype='<f4')
            nb = name.encode()
            f.write(struct.pack('<B', len(nb)))
            f.write(nb)
            f.write(struct.pack('<B', arr.ndim))
            for d in arr.shape:
                f.write(struct.pack('<I', d))
            f.write(arr.tobytes())

write_blob('silero_vad_16k.svad')
import os
print(f"wrote silero_vad_16k.svad ({os.path.getsize('silero_vad_16k.svad')} bytes)")
