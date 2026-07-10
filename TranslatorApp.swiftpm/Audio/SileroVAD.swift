import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

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
/// Playgrounds builds apps WITHOUT optimization (-Onone), so this file is
/// written for debug-build speed: weights and scratch live in flat
/// manually-managed buffers (no nested arrays, no bounds checks, no
/// per-frame allocation), and the matrix work goes through Accelerate's
/// BLAS — precompiled, hence immune to -Onone — with an equivalent scalar
/// path compiled where Accelerate is unavailable (the Linux verification
/// harness in tools/silero/).
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

    /// Parsed weight blob, shared by every channel's instance. All tensors
    /// are flat row-major buffers, manually managed so the hot path never
    /// touches Array bridging or bounds checks.
    final class Weights {
        /// STFT basis, 258×256: rows 0..<129 real, 129..<258 imaginary.
        let stftBasis: UnsafeMutablePointer<Float>
        /// Encoder convs re-laid out per kernel tap at load time:
        /// convTaps[layer][k] is a dense [cout × cin] matrix, so each conv
        /// runs as three strided BLAS gemv accumulations with no im2col
        /// packing loop (Playgrounds builds -Onone; scalar packing is the
        /// kind of loop that dies there).
        let convTaps: [[UnsafeMutablePointer<Float>]]
        let convB: [UnsafeMutablePointer<Float>]
        static let convDims: [(cout: Int, cin: Int)] = [(128, 129), (64, 128), (64, 64), (128, 64)]
        /// LSTM cell, PyTorch gate order (i, f, g, o): [512 × 128] each.
        let lstmWih: UnsafeMutablePointer<Float>
        let lstmWhh: UnsafeMutablePointer<Float>
        /// bias_ih + bias_hh pre-summed, [512].
        let lstmBias: UnsafeMutablePointer<Float>
        /// Final 1×1 conv, [128] + scalar bias.
        let outW: UnsafeMutablePointer<Float>
        let outB: Float

        private let allocations: [UnsafeMutablePointer<Float>]

        deinit {
            for p in allocations { p.deallocate() }
        }

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

            var owned: [UnsafeMutablePointer<Float>] = []
            /// Copy a validated tensor into a fresh flat buffer.
            func flat(_ name: String, _ expected: [Int]) -> UnsafeMutablePointer<Float>? {
                guard let t = tensors[name], t.dims == expected else { return nil }
                let p = UnsafeMutablePointer<Float>.allocate(capacity: t.values.count)
                t.values.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: $0.count) }
                owned.append(p)
                return p
            }

            guard let basis = flat("stft.forward_basis_buffer", [258, 1, 256]) else { return nil }
            var convTapsAll: [[UnsafeMutablePointer<Float>]] = []
            var convBs: [UnsafeMutablePointer<Float>] = []
            for (layer, dims) in Self.convDims.enumerated() {
                guard let t = tensors["encoder.\(layer).reparam_conv.weight"],
                      t.dims == [dims.cout, dims.cin, 3],
                      let b = flat("encoder.\(layer).reparam_conv.bias", [dims.cout])
                else { for p in owned { p.deallocate() }; return nil }
                // Split [cout][cin][3] into three dense [cout × cin] tap matrices.
                var taps: [UnsafeMutablePointer<Float>] = []
                for k in 0..<3 {
                    let p = UnsafeMutablePointer<Float>.allocate(capacity: dims.cout * dims.cin)
                    t.values.withUnsafeBufferPointer { src in
                        for oi in 0..<(dims.cout * dims.cin) { p[oi] = src[oi * 3 + k] }
                    }
                    owned.append(p)
                    taps.append(p)
                }
                convTapsAll.append(taps)
                convBs.append(b)
            }
            guard let wih = flat("decoder.rnn.weight_ih", [512, 128]),
                  let whh = flat("decoder.rnn.weight_hh", [512, 128]),
                  let bih = tensors["decoder.rnn.bias_ih"], bih.dims == [512],
                  let bhh = tensors["decoder.rnn.bias_hh"], bhh.dims == [512],
                  let ow = flat("decoder.decoder.2.weight", [1, 128, 1]),
                  let ob = tensors["decoder.decoder.2.bias"], ob.dims == [1]
            else { for p in owned { p.deallocate() }; return nil }

            let bias = UnsafeMutablePointer<Float>.allocate(capacity: 512)
            for k in 0..<512 { bias[k] = bih.values[k] + bhh.values[k] }
            owned.append(bias)

            stftBasis = basis
            convTaps = convTapsAll
            convB = convBs
            lstmWih = wih
            lstmWhh = whh
            lstmBias = bias
            outW = ow
            outB = ob.values[0]
            allocations = owned
        }
    }

    // MARK: - Per-channel state and scratch

    private let weights: Weights
    /// One manually-managed slab: context/hidden/cell state plus every
    /// intermediate of the forward pass. Layout below; nothing in process()
    /// allocates or touches an Array.
    private let slab: UnsafeMutablePointer<Float>
    private static let slabCount = 64 + 128 + 128        // context, hidden, cell
        + 640                                            // padded input
        + 258 * 4                                        // spectrum
        + 129 * 4                                        // ping buffer (mag / activations)
        + 129 * 4                                        // pong buffer
        + 512                                            // LSTM gates

    private var context: UnsafeMutablePointer<Float> { slab }
    private var hidden: UnsafeMutablePointer<Float> { slab + 64 }
    private var cell: UnsafeMutablePointer<Float> { slab + 192 }
    private var x: UnsafeMutablePointer<Float> { slab + 320 }
    private var spec: UnsafeMutablePointer<Float> { slab + 960 }
    private var ping: UnsafeMutablePointer<Float> { slab + 1992 }
    private var pong: UnsafeMutablePointer<Float> { slab + 2508 }
    private var gates: UnsafeMutablePointer<Float> { slab + 3024 }

    init(weights: Weights) {
        self.weights = weights
        slab = UnsafeMutablePointer<Float>.allocate(capacity: Self.slabCount)
        slab.update(repeating: 0, count: Self.slabCount)
    }

    deinit {
        slab.deallocate()
    }

    func reset() {
        slab.update(repeating: 0, count: 320)   // context + hidden + cell
    }

    /// Convenience for callers holding an Array (verification harness).
    func process(frame: [Float]) -> Float {
        precondition(frame.count == Self.frameLength)
        return frame.withUnsafeBufferPointer { process($0.baseAddress!) }
    }

    /// Speech probability for one 512-sample 16 kHz frame. Carries LSTM
    /// state and the trailing 64 samples of context to the next call.
    func process(_ frame: UnsafePointer<Float>) -> Float {
        let w = weights

        // Assemble input: context ++ frame, reflect-padded right by 64
        // (x[576+i] = x[574-i]).
        x.update(from: context, count: 64)
        (x + 64).update(from: frame, count: 512)
        for i in 0..<64 { x[576 + i] = x[574 - i] }
        context.update(from: frame + 448, count: 64)

        // STFT as strided conv (kernel 256, hop 128) over 4 frames: one
        // 258×256 gemv per frame, straight off the padded input (the frame
        // windows are contiguous, so nothing needs packing); then magnitude
        // [129][4] row-major.
        for f in 0..<4 {
            Self.gemv(a: w.stftBasis, rows: 258, cols: 256,
                      x: x + f * 128, incX: 1, y: spec + f, incY: 4, accumulate: false)
        }
        for bin in 0..<129 {
            let re = spec + bin * 4
            let im = spec + (bin + 129) * 4
            let dst = ping + bin * 4
            for f in 0..<4 { dst[f] = (re[f] * re[f] + im[f] * im[f]).squareRoot() }
        }

        // Encoder: Conv1d(k=3, pad=1) + ReLU with strides 1,2,2,1. Each
        // output column accumulates one gemv per in-range kernel tap, using
        // strides to read input columns / write output columns in place —
        // no packing loops. Time lengths: 4 → 4 → 2 → 1 → 1.
        var input = ping
        var output = pong
        var t = 4
        for (layer, dims) in Weights.convDims.enumerated() {
            let stride = layer == 1 || layer == 2 ? 2 : 1
            let tout = (t + 2 - 3) / stride + 1
            let bias = w.convB[layer]
            for o in 0..<dims.cout {
                let row = output + o * tout
                for ot in 0..<tout { row[ot] = bias[o] }
            }
            for ot in 0..<tout {
                for k in 0..<3 {
                    let idx = ot * stride - 1 + k
                    guard idx >= 0 && idx < t else { continue }   // zero pad
                    Self.gemv(a: w.convTaps[layer][k], rows: dims.cout, cols: dims.cin,
                              x: input + idx, incX: t, y: output + ot, incY: tout, accumulate: true)
                }
            }
            for o in 0..<(dims.cout * tout) { output[o] = max(output[o], 0) }
            swap(&input, &output)
            t = tout
        }
        let xt = input   // [128 × 1]

        // LSTM cell, PyTorch gate order i,f,g,o.
        gates.update(from: w.lstmBias, count: 512)
        Self.gemv(a: w.lstmWih, rows: 512, cols: 128, x: xt, incX: 1, y: gates, incY: 1, accumulate: true)
        Self.gemv(a: w.lstmWhh, rows: 512, cols: 128, x: hidden, incX: 1, y: gates, incY: 1, accumulate: true)
        for k in 0..<128 {
            let i = Self.sigmoid(gates[k])
            let f = Self.sigmoid(gates[128 + k])
            let g = Foundation.tanh(gates[256 + k])
            let o = Self.sigmoid(gates[384 + k])
            cell[k] = f * cell[k] + i * g
            hidden[k] = o * Foundation.tanh(cell[k])
        }

        // ReLU → 1×1 conv → sigmoid.
        var logit = weights.outB
        for k in 0..<128 { logit += w.outW[k] * max(hidden[k], 0) }
        return Self.sigmoid(logit)
    }

    // MARK: - Math

    /// y[r·incY] (+)= A[rows×cols] · x[c·incX], A row-major dense. All the
    /// model's heavy math funnels through this one call so the device build
    /// spends its time inside BLAS (precompiled, immune to Playgrounds'
    /// -Onone) rather than in interpreted Swift loops.
    @inline(__always)
    private static func gemv(a: UnsafePointer<Float>, rows: Int, cols: Int,
                             x: UnsafePointer<Float>, incX: Int,
                             y: UnsafeMutablePointer<Float>, incY: Int, accumulate: Bool) {
        #if canImport(Accelerate)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(cols),
                    1, a, Int32(cols), x, Int32(incX), accumulate ? 1 : 0, y, Int32(incY))
        #else
        for row in 0..<rows {
            let arow = a + row * cols
            var sum: Float = 0
            for kk in 0..<cols { sum += arow[kk] * x[kk * incX] }
            let dst = y + row * incY
            dst.pointee = accumulate ? dst.pointee + sum : sum
        }
        #endif
    }

    @inline(__always)
    private static func sigmoid(_ v: Float) -> Float {
        1 / (1 + Foundation.exp(-v))
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
    /// Reused per-buffer workspace (history ++ new samples).
    private var work: [Float] = []
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
        var consumed = 0
        pending.withUnsafeBufferPointer { p in
            while pending.count - consumed >= SileroVAD.frameLength {
                probability = vad.process(p.baseAddress! + consumed)
                consumed += SileroVAD.frameLength
                onFrame?(probability)
                maxProbability = max(maxProbability ?? 0, probability)
            }
        }
        if consumed > 0 { pending.removeFirst(consumed) }
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
        work.removeAll(keepingCapacity: true)
        work.append(contentsOf: history)
        work.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        // Each *new* sample advances the decimation phase; when the phase
        // hits 0 and a full FIR window is available, emit one output sample.
        // (The first taps-1 samples of the stream produce no output: a
        // ~1.3 ms startup transient, irrelevant to gating.)
        let base = work.count - count
        work.withUnsafeBufferPointer { pi in
            fir.withUnsafeBufferPointer { pk in
                let signal = pi.baseAddress!
                let kernel = pk.baseAddress!
                for j in 0..<count {
                    let index = base + j
                    if phase == 0 && index >= taps - 1 {
                        // Convolution against a symmetric kernel == forward
                        // dot product over the window (fir is palindromic).
                        var acc: Float = 0
                        let window = signal + index - (taps - 1)
                        #if canImport(Accelerate)
                        vDSP_dotpr(window, 1, kernel, 1, &acc, vDSP_Length(taps))
                        #else
                        for k in 0..<taps { acc += kernel[k] * window[k] }
                        #endif
                        pending.append(acc)
                    }
                    phase = (phase + 1) % factor
                }
            }
        }
        // Keep the last taps-1 samples as FIR history for the next buffer.
        let keep = min(taps - 1, work.count)
        history.removeAll(keepingCapacity: true)
        history.append(contentsOf: work.suffix(keep))
    }
}
