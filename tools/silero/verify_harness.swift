import Foundation

// Verification harness for SileroVAD.swift — runs on Linux against
// onnxruntime-generated test vectors.

func die(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

guard let blob = try? Data(contentsOf: dir.appendingPathComponent("silero_vad_16k.svad")),
      let weights = SileroVAD.Weights(data: blob) else { die("cannot load weights") }
print("weights loaded (\(blob.count) bytes)")

func readFloats(_ data: Data, _ offset: inout Int, _ n: Int) -> [Float] {
    var out = [Float](repeating: 0, count: n)
    data.withUnsafeBytes { raw in
        for i in 0..<n {
            out[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: offset + i * 4, as: UInt32.self))
        }
    }
    offset += n * 4
    return out
}
func readU32(_ data: Data, _ offset: inout Int) -> Int {
    defer { offset += 4 }
    return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
}

// ---- Test A: model-level, 16 kHz frames vs onnxruntime -------------------
do {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("vectors_model.bin")) else {
        die("missing vectors_model.bin")
    }
    var offset = 0
    let count = readU32(data, &offset)
    let vad = SileroVAD(weights: weights)
    var maxDiff: Float = 0
    let t0 = Date()
    for _ in 0..<count {
        let frame = readFloats(data, &offset, 512)
        let expected = readFloats(data, &offset, 1)[0]
        let got = vad.process(frame: frame)
        maxDiff = max(maxDiff, abs(got - expected))
    }
    let dt = Date().timeIntervalSince(t0)
    let rtf = (Double(count) * 0.032) / dt
    print(String(format: "Test A: %d frames, max |prob diff| = %.2e, %.0fx realtime single channel", count, maxDiff, rtf))
    if maxDiff > 5e-4 { die("model mismatch vs onnxruntime") }
}

// ---- Test B: full 48 kHz pipeline (FIR decimator + model) ----------------
do {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("vectors_stream.bin")) else {
        die("missing vectors_stream.bin")
    }
    var offset = 0
    let sampleCount = readU32(data, &offset)
    let samples = readFloats(data, &offset, sampleCount)
    let probCount = readU32(data, &offset)
    let expected = readFloats(data, &offset, probCount)

    let stream = StreamingVAD(weights: weights)
    var got: [Float] = []
    stream.onFrame = { got.append($0) }
    // Feed with an awkward, varying buffer size to exercise re-blocking.
    let bufferSizes = [480, 1024, 960, 333, 2048, 479]
    var index = 0
    var bufferPick = 0
    while index < sampleCount {
        let n = min(bufferSizes[bufferPick % bufferSizes.count], sampleCount - index)
        bufferPick += 1
        samples.withUnsafeBufferPointer { p in
            _ = stream.feed(p.baseAddress! + index, count: n, sampleRate: 48000)
        }
        index += n
    }
    // The Swift path only sees whole completed frames; compare the overlap.
    let n = min(got.count, probCount)
    guard n >= probCount - 1 else { die("pipeline produced \(got.count) frames, expected ~\(probCount)") }
    var maxDiff: Float = 0
    for i in 0..<n { maxDiff = max(maxDiff, abs(got[i] - expected[i])) }
    print(String(format: "Test B: %d/%d frames, max |prob diff| = %.2e (decimator + model)", n, probCount, maxDiff))
    if maxDiff > 5e-3 { die("pipeline mismatch") }

    // Discrimination summary from the Swift pipeline itself.
    let sec = 16000 / 512
    let segments: [(String, Range<Int>)] = [
        ("silence", 0..<(2 * sec)),
        ("speech", (2 * sec)..<(22 * sec)),
        ("noise", (22 * sec)..<(26 * sec)),
        ("quiet speech", (26 * sec)..<(36 * sec)),
    ]
    for (name, r) in segments where r.upperBound <= got.count {
        let s = got[r]
        let mean = s.reduce(0, +) / Float(s.count)
        let frac = Float(s.filter { $0 > 0.5 }.count) / Float(s.count)
        print(String(format: "  %-13s mean %.3f  frac>0.5 %.2f", name, mean, frac))
    }
}

print("ALL TESTS PASSED")
