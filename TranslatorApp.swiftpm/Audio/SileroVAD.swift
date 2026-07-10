import Foundation

/// Pure-Swift port of the Silero VAD v5 model (16 kHz path), MIT-licensed by
/// the Silero Team (https://github.com/snakers4/silero-vad).
///
/// Swift Playgrounds can't link binary frameworks, which rules out ONNX
/// Runtime, and a Core ML conversion can't be produced or debugged on the
/// iPad this app is developed on. So the network — reflect-pad → STFT (as a
/// 258×256 conv, hop 128) → magnitude → 4×(Conv1d+ReLU) → LSTM cell →
/// ReLU → 1×1 conv → sigmoid — is implemented directly. The forward pass
/// was verified against onnxruntime on the official model file to within
/// 1e-4 per frame with LSTM state carried across hundreds of frames.
///
/// The model consumes 512-sample frames at 16 kHz (32 ms) with 64 samples of
/// leading context from the previous frame, and returns P(speech) per frame.
/// Instances are NOT thread-safe; each audio channel owns one instance
/// (per-channel LSTM state) and calls it from the audio queue only.
final class SileroVAD {

    static let sampleRate = 16000
    static let frameLength = 512
    private static let contextLength = 64

    // MARK: - Weights (shared, immutable)

    /// Parsed weight blob, shared by every channel's instance.
    final class Weights {
        // stft basis split into real/imag halves: [129][256]
        var stftReal: [[Float]] = []
        var stftImag: [[Float]] = []
        // encoder convs: weight [out][in][3], bias [out]
        var convW: [[[[Float]]]] = []   // 4 layers
        var convB: [[Float]] = []
        // LSTM cell, PyTorch gate order (i, f, g, o) stacked in rows of 4×128
        var lstmWih: [[Float]] = []     // [512][128]
        var lstmWhh: [[Float]] = []     // [512][128]
        var lstmBias: [Float] = []      // [512] = bias_ih + bias_hh, pre-summed
        // final 1×1 conv
        var outW: [Float] = []          // [128]
        var outB: Float = 0

        /// Parse the .svad container written by tools/silero/extract_and_verify.py:
        /// "SVAD", u32 version, u32 tensor count, then per tensor
        /// (u8 name length, name, u8 rank, u32 dims…, float32 LE data).
        init?(data: Data) {
            var offset = 0
            func read<T>(_: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard offset + size <= data.count else { return nil }
                defer { offset += size }
                return data.subdata(in: offset..<offset + size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            }
            guard data.count > 12,
                  data.subdata(in: 0..<4) == Data("SVAD".utf8) else { return nil }
            offset = 4
            guard let version: UInt32 = read(UInt32.self), version == 1,
                  let count: UInt32 = read(UInt32.self) else { return nil }

            var tensors: [String: (dims: [Int], values: [Float])] = [:]
            for _ in 0..<count {
                guard let nameLen: UInt8 = read(UInt8.self),
                      offset + Int(nameLen) <= data.count,
                      let name = String(data: data.subdata(in: offset..<offset + Int(nameLen)), encoding: .utf8)
                else { return nil }
                offset += Int(nameLen)
                guard let rank: UInt8 = read(UInt8.self) else { return nil }
                var dims: [Int] = []
                for _ in 0..<rank {
                    guard let d: UInt32 = read(UInt32.self) else { return nil }
                    dims.append(Int(d))
                }
                let elementCount = dims.reduce(1, *)
                let byteCount = elementCount * 4
                guard offset + byteCount <= data.count else { return nil }
                var values = [Float](repeating: 0, count: elementCount)
                data.subdata(in: offset..<offset + byteCount).withUnsafeBytes { raw in
                    for i in 0..<elementCount {
                        values[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    }
                }
                offset += byteCount
                tensors[name] = (dims, values)
            }

            func rows(_ name: String, _ expected: [Int]) -> [[Float]]? {
                guard let t = tensors[name], t.dims == expected else { return nil }
                let cols = expected[1]
                return (0..<expected[0]).map { Array(t.values[$0 * cols..<($0 + 1) * cols]) }
            }
            // STFT basis (258, 1, 256) -> real 0..<129, imag 129..<258
            guard let stft = tensors["stft.forward_basis_buffer"], stft.dims == [258, 1, 256] else { return nil }
            for r in 0..<129 { stftReal.append(Array(stft.values[r * 256..<(r + 1) * 256])) }
            for r in 129..<258 { stftImag.append(Array(stft.values[r * 256..<(r + 1) * 256])) }

            let convShapes = [[128, 129, 3], [64, 128, 3], [64, 64, 3], [128, 64, 3]]
            for (layer, shape) in convShapes.enumerated() {
                guard let w = tensors["encoder.\(layer).reparam_conv.weight"], w.dims == shape,
                      let b = tensors["encoder.\(layer).reparam_conv.bias"], b.dims == [shape[0]]
                else { return nil }
                let (cout, cin, k) = (shape[0], shape[1], shape[2])
                var weight: [[[Float]]] = []
                weight.reserveCapacity(cout)
                for o in 0..<cout {
                    var perIn: [[Float]] = []
                    perIn.reserveCapacity(cin)
                    for i in 0..<cin {
                        let base = (o * cin + i) * k
                        perIn.append(Array(w.values[base..<base + k]))
                    }
                    weight.append(perIn)
                }
                convW.append(weight)
                convB.append(b.values)
            }

            guard let wih = rows("decoder.rnn.weight_ih", [512, 128]),
                  let whh = rows("decoder.rnn.weight_hh", [512, 128]),
                  let bih = tensors["decoder.rnn.bias_ih"], bih.dims == [512],
                  let bhh = tensors["decoder.rnn.bias_hh"], bhh.dims == [512],
                  let ow = tensors["decoder.decoder.2.weight"], ow.dims == [1, 128, 1],
                  let ob = tensors["decoder.decoder.2.bias"], ob.dims == [1]
            else { return nil }
            lstmWih = wih
            lstmWhh = whh
            lstmBias = zip(bih.values, bhh.values).map(+)
            outW = ow.values
            outB = ob.values[0]
        }
    }

    // MARK: - Per-channel state

    private let weights: Weights
    private var context = [Float](repeating: 0, count: SileroVAD.contextLength)
    private var hidden = [Float](repeating: 0, count: 128)
    private var cell = [Float](repeating: 0, count: 128)

    init(weights: Weights) {
        self.weights = weights
    }

    func reset() {
        context = [Float](repeating: 0, count: Self.contextLength)
        hidden = [Float](repeating: 0, count: 128)
        cell = [Float](repeating: 0, count: 128)
    }

    /// Speech probability for one 512-sample 16 kHz frame. Carries LSTM
    /// state and the trailing 64 samples of context to the next call.
    func process(frame: [Float]) -> Float {
        precondition(frame.count == Self.frameLength)
        var x = context + frame                                // 576
        context = Array(frame.suffix(Self.contextLength))

        // Reflect-pad right by 64: x[576+i] = x[574-i]
        x.reserveCapacity(640)
        for i in 0..<64 { x.append(x[574 - i]) }

        // STFT as strided conv (kernel 256, hop 128) -> magnitude [129][4]
        var mag = [[Float]](repeating: [Float](repeating: 0, count: 4), count: 129)
        x.withUnsafeBufferPointer { px in
            for f in 0..<4 {
                let start = f * 128
                for bin in 0..<129 {
                    var re: Float = 0
                    var im: Float = 0
                    weights.stftReal[bin].withUnsafeBufferPointer { pr in
                        weights.stftImag[bin].withUnsafeBufferPointer { pi in
                            for k in 0..<256 {
                                let s = px[start + k]
                                re += pr[k] * s
                                im += pi[k] * s
                            }
                        }
                    }
                    mag[bin][f] = (re * re + im * im).squareRoot()
                }
            }
        }

        // Encoder: Conv1d(k=3, pad=1) + ReLU, strides 1,2,2,1
        var act = mag
        for layer in 0..<4 {
            act = Self.convReLU(act, weight: weights.convW[layer], bias: weights.convB[layer],
                                stride: layer == 1 || layer == 2 ? 2 : 1)
        }
        // act is now [128][1]
        let xt = act.map { $0[0] }

        // LSTM cell, PyTorch gate order i,f,g,o
        var gates = weights.lstmBias
        for row in 0..<512 {
            var sum: Float = 0
            weights.lstmWih[row].withUnsafeBufferPointer { pw in
                for k in 0..<128 { sum += pw[k] * xt[k] }
            }
            weights.lstmWhh[row].withUnsafeBufferPointer { pw in
                for k in 0..<128 { sum += pw[k] * hidden[k] }
            }
            gates[row] += sum
        }
        for k in 0..<128 {
            let i = Self.sigmoid(gates[k])
            let f = Self.sigmoid(gates[128 + k])
            let g = Self.tanhf(gates[256 + k])
            let o = Self.sigmoid(gates[384 + k])
            cell[k] = f * cell[k] + i * g
            hidden[k] = o * Self.tanhf(cell[k])
        }

        // ReLU -> 1x1 conv -> sigmoid
        var logit = weights.outB
        for k in 0..<128 { logit += weights.outW[k] * max(hidden[k], 0) }
        return Self.sigmoid(logit)
    }

    // MARK: - Math

    /// Conv1d with kernel 3, zero padding 1, given stride, then ReLU.
    private static func convReLU(_ input: [[Float]], weight: [[[Float]]], bias: [Float], stride: Int) -> [[Float]] {
        let cin = input.count
        let t = input[0].count
        let cout = weight.count
        let tout = (t + 2 - 3) / stride + 1
        var out = [[Float]](repeating: [Float](repeating: 0, count: tout), count: cout)
        for o in 0..<cout {
            let wo = weight[o]
            for ot in 0..<tout {
                let base = ot * stride - 1        // input index of kernel tap 0
                var sum = bias[o]
                for i in 0..<cin {
                    let wi = wo[i]
                    let row = input[i]
                    if base >= 0 && base + 2 < t {
                        sum += wi[0] * row[base] + wi[1] * row[base + 1] + wi[2] * row[base + 2]
                    } else {
                        for k in 0..<3 {
                            let idx = base + k
                            if idx >= 0 && idx < t { sum += wi[k] * row[idx] }
                        }
                    }
                }
                out[o][ot] = max(sum, 0)
            }
        }
        return out
    }

    private static func sigmoid(_ v: Float) -> Float {
        1 / (1 + Foundation.exp(-v))
    }

    private static func tanhf(_ v: Float) -> Float {
        Foundation.tanh(v)
    }
}

/// Streams arbitrary-length audio at an integer multiple of 16 kHz into
/// 512-sample 16 kHz VAD frames: anti-alias FIR + decimation, frame
/// re-blocking, and the per-channel model state. Not thread-safe; one
/// instance per channel, audio queue only.
final class StreamingVAD {

    private let vad: SileroVAD
    /// Decimation factor (3 for the 48 kHz engine rate). 1 = pass-through.
    private var factor = 1
    private var configuredRate = 0.0
    /// Windowed-sinc anti-alias lowpass, odd length; empty when factor == 1.
    private var fir: [Float] = []
    /// Trailing input samples carried between buffers for FIR history.
    private var history: [Float] = []
    /// Input-sample phase within the current decimation stride.
    private var phase = 0
    /// 16 kHz samples accumulated toward the next 512-sample frame.
    private var pending: [Float] = []
    /// Most recent model output.
    private(set) var probability: Float = 0
    /// Invoked once per completed 32 ms frame with that frame's probability
    /// (a single feed() can complete several frames). Unused by the app;
    /// tools/silero/verify_harness.swift depends on it.
    var onFrame: ((Float) -> Void)?

    init(weights: SileroVAD.Weights) {
        vad = SileroVAD(weights: weights)
    }

    func reset() {
        vad.reset()
        history.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        phase = 0
        probability = 0
    }

    /// Feed one buffer of mono samples. Returns the highest probability among
    /// the 32 ms frames this buffer completed — a short burst of speech
    /// anywhere in a long buffer counts — or the most recent probability if
    /// the buffer was too short to complete a frame.
    /// Returns nil if the sample rate isn't an integer multiple of 16 kHz.
    @discardableResult
    func feed(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Float? {
        if sampleRate != configuredRate {
            let ratio = sampleRate / Double(SileroVAD.sampleRate)
            guard ratio >= 1, ratio == ratio.rounded() else { return nil }
            configure(factor: Int(ratio), sampleRate: sampleRate)
        }

        if factor == 1 {
            pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        } else {
            decimate(samples, count: count)
        }

        var maxProbability: Float?
        while pending.count >= SileroVAD.frameLength {
            let frame = Array(pending.prefix(SileroVAD.frameLength))
            pending.removeFirst(SileroVAD.frameLength)
            probability = vad.process(frame: frame)
            onFrame?(probability)
            maxProbability = max(maxProbability ?? 0, probability)
        }
        return maxProbability ?? probability
    }

    private func configure(factor newFactor: Int, sampleRate: Double) {
        factor = newFactor
        configuredRate = sampleRate
        history.removeAll(keepingCapacity: true)
        phase = 0
        pending.removeAll(keepingCapacity: true)
        guard factor > 1 else { fir = []; return }
        // Windowed-sinc lowpass at 0.45 * 16 kHz output rate (7.2 kHz),
        // Hamming window, 63 taps: >50 dB alias rejection, speech untouched.
        let taps = 63
        let cutoff = 0.45 / Double(factor)   // normalized to input rate
        let mid = Double(taps - 1) / 2
        var kernel = [Float](repeating: 0, count: taps)
        var sum = 0.0
        for n in 0..<taps {
            let t = Double(n) - mid
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(taps - 1))
            let v = sinc * window
            kernel[n] = Float(v)
            sum += v
        }
        for n in 0..<taps { kernel[n] /= Float(sum) }   // unity DC gain
        fir = kernel
    }

    private func decimate(_ samples: UnsafePointer<Float>, count: Int) {
        let taps = fir.count
        var input = history
        input.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        // Each *new* sample advances the decimation phase; when the phase
        // hits 0 and a full FIR window is available, emit one output sample.
        // (The first taps-1 samples of the stream produce no output: a
        // ~1.3 ms startup transient, irrelevant to gating.)
        let base = input.count - count
        input.withUnsafeBufferPointer { pi in
            fir.withUnsafeBufferPointer { pk in
                for j in 0..<count {
                    let index = base + j
                    if phase == 0 && index >= taps - 1 {
                        var acc: Float = 0
                        for k in 0..<taps { acc += pk[k] * pi[index - k] }
                        pending.append(acc)
                    }
                    phase = (phase + 1) % factor
                }
            }
        }
        // Keep the last taps-1 samples as FIR history for the next buffer.
        history = Array(input.suffix(taps - 1))
    }
}
