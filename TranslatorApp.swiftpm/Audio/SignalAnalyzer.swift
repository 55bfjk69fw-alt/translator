import Foundation
import AVFoundation
import Accelerate
import CoreGraphics
import Combine

/// Off-pipeline signal analysis for the Signal tab: gate-decision history,
/// waveform envelopes, FFT spectra/spectrograms, and pair-correlation state.
///
/// Threading: `ingest` is called on AppModel's audioQueue and does nothing
/// but a flag check and an async hop when the tab is hidden or frozen. All
/// real work (FFT, ring writes, image building) happens on a dedicated
/// serial queue at `.utility` QoS — strictly below the pipeline's
/// `.userInitiated` — so analysis can never starve translation. The UI reads
/// one immutable `SignalSnapshot` value published on the main thread.
final class SignalAnalyzer: ObservableObject {

    // MARK: - Published UI state (main thread only)

    @Published private(set) var snapshot = SignalSnapshot.empty
    @Published private(set) var isFrozen = false

    // MARK: - Sizing

    /// One gate point per 200 ms buffer: 100 points = 20 s of history.
    static let gateHistoryCount = 100
    static let gateWindowSeconds: Double = 20
    /// 10 ms min/max envelope bins; 1000 = 10 s of waveform.
    static let waveformBinSeconds = 0.010
    static let waveformHistoryCount = 1000
    static let fftSize = 1024            // 46.9 Hz/bin @ 48 kHz
    static let fftHop = 2400             // 4 spectrogram columns per 200 ms buffer
    static let spectrogramColumns = 256  // ~12.8 s of history
    static let spectrogramBins = 96      // log-spaced 60 Hz ... 12 kHz
    static let spectrogramFloorDB: Float = -80
    static let pairHoldSeconds = 1.5
    static let pairEventCount = 300
    static let clipLevel: Float = 0.999
    static let publishInterval = 0.1     // <=10 Hz UI updates

    // MARK: - Cross-queue flags

    private let stateLock = NSLock()
    private var enabled = false
    private var frozen = false
    private var pending = 0              // backpressure: drop instead of queueing

    // MARK: - Analysis-queue-confined state

    private let queue = DispatchQueue(label: "translator.signal.analysis", qos: .utility)

    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private let hannWindow = vDSP.window(ofType: Float.self,
                                         usingSequence: .hanningDenormalized,
                                         count: SignalAnalyzer.fftSize,
                                         isHalfWindow: false)
    private let fftRealIn = UnsafeMutablePointer<Float>.allocate(capacity: SignalAnalyzer.fftSize)
    private let fftImagIn = UnsafeMutablePointer<Float>.allocate(capacity: SignalAnalyzer.fftSize)
    private let fftRealOut = UnsafeMutablePointer<Float>.allocate(capacity: SignalAnalyzer.fftSize)
    private let fftImagOut = UnsafeMutablePointer<Float>.allocate(capacity: SignalAnalyzer.fftSize)
    /// FFT-bin range feeding each log-spaced display bin (rebuilt on rate change).
    private var binRanges: [Range<Int>] = []
    private var binTableRate: Double = 0

    private var channelCount = 0
    private var currentSampleRate: Double = 48_000
    private var startedAt = Date()
    private var lastPublish = Date.distantPast

    private var gateHistory: [RingBuffer<GatePoint>] = []
    private var waveHistory: [RingBuffer<WaveBin>] = []
    private var clipCounts: [Int] = []
    private var lastSpectrum: [[Float]] = []
    /// Per channel: spectrogramColumns x spectrogramBins RGBX pixels, ring on columns.
    private var spectroPixels: [[UInt8]] = []
    private var spectroHead = -1
    private var pairHold: [Int: (correlation: Float, winner: Int?, at: Date)] = [:]
    private var pairEvents = RingBuffer<PairEvent>(capacity: SignalAnalyzer.pairEventCount)

    /// Viridis-style ramp: perceptually monotonic in lightness, CVD-safe.
    private let colormap: [(r: UInt8, g: UInt8, b: UInt8)] = SignalAnalyzer.makeColormap()

    deinit {
        fftRealIn.deallocate()
        fftImagIn.deallocate()
        fftRealOut.deallocate()
        fftImagOut.deallocate()
    }

    // MARK: - API

    /// Toggle from SignalView.onAppear/.onDisappear. Enabling resets history.
    func setEnabled(_ on: Bool) {
        stateLock.lock()
        let wasEnabled = enabled
        enabled = on
        stateLock.unlock()
        if on && !wasEnabled {
            queue.async { self.resetState() }
        }
    }

    /// Freeze keeps the last snapshot on screen and drops incoming data.
    /// The audio pipeline itself is untouched. Call on the main thread.
    func setFrozen(_ on: Bool) {
        stateLock.lock()
        frozen = on
        stateLock.unlock()
        isFrozen = on
    }

    /// Called on audioQueue after every gate evaluation. Cheap when the tab
    /// is hidden or frozen: one lock, one flag check.
    func ingest(buffers: [AVAudioPCMBuffer], frames: Int, sampleRate: Double, telemetry: ChannelGate.Telemetry) {
        guard !buffers.isEmpty, frames > 0 else { return }
        stateLock.lock()
        let active = enabled && !frozen && pending < 4
        if active { pending += 1 }
        stateLock.unlock()
        guard active else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.process(buffers: buffers, frames: frames, sampleRate: sampleRate, telemetry: telemetry)
            self.stateLock.lock()
            self.pending -= 1
            self.stateLock.unlock()
        }
    }

    /// Build the export JSON for whatever the rings currently hold (freeze
    /// first so it matches what's on screen). Completion runs on main.
    func exportSnapshot(channelNames: [String], completion: @escaping (String) -> Void) {
        queue.async {
            let json = SignalExport.json(
                channelNames: channelNames,
                sampleRate: self.currentSampleRate,
                settings: GateSettingsSnapshot.current(),
                gateHistory: self.gateHistory.map { $0.ordered() },
                waveHistory: self.waveHistory.map { $0.ordered() },
                clipCounts: self.clipCounts,
                pairEvents: self.pairEvents.ordered()
            )
            DispatchQueue.main.async { completion(json) }
        }
    }

    // MARK: - Processing (analysis queue)

    private func resetState() {
        channelCount = 0
        gateHistory = []
        waveHistory = []
        clipCounts = []
        lastSpectrum = []
        spectroPixels = []
        spectroHead = -1
        pairHold = [:]
        pairEvents = RingBuffer(capacity: Self.pairEventCount)
        startedAt = Date()
        lastPublish = .distantPast
        DispatchQueue.main.async { self.snapshot = .empty }
    }

    private func ensureChannels(_ count: Int) {
        guard channelCount != count else { return }
        channelCount = count
        gateHistory = (0..<count).map { _ in RingBuffer(capacity: Self.gateHistoryCount) }
        waveHistory = (0..<count).map { _ in RingBuffer(capacity: Self.waveformHistoryCount) }
        clipCounts = Array(repeating: 0, count: count)
        lastSpectrum = Array(repeating: Array(repeating: Self.spectrogramFloorDB, count: Self.spectrogramBins), count: count)
        spectroPixels = Array(
            repeating: [UInt8](repeating: 0, count: Self.spectrogramColumns * Self.spectrogramBins * 4),
            count: count
        )
        spectroHead = -1
        pairHold = [:]
    }

    private func process(buffers: [AVAudioPCMBuffer], frames: Int, sampleRate: Double, telemetry: ChannelGate.Telemetry) {
        let count = min(buffers.count, telemetry.channels.count)
        guard count > 0 else { return }
        ensureChannels(count)
        currentSampleRate = sampleRate
        if binTableRate != sampleRate { rebuildBinTable(sampleRate: sampleRate) }

        let now = Date()
        let t = now.timeIntervalSince(startedAt)

        for channel in 0..<count {
            guard let data = buffers[channel].floatChannelData else { continue }
            let samples = UnsafePointer(data[0])
            let tele = telemetry.channels[channel]
            gateHistory[channel].append(GatePoint(
                t: t,
                rms: tele.rms,
                noiseFloor: tele.noiseFloor,
                threshold: tele.effectiveThreshold,
                voiced: tele.voiced,
                pass: tele.pass,
                bleed: tele.bleed
            ))
            appendWaveform(samples: samples, frames: frames, sampleRate: sampleRate, channel: channel)
        }
        appendSpectra(buffers: buffers, count: count, frames: frames)

        for pair in telemetry.pairs {
            pairHold[pairKey(pair.a, pair.b)] = (pair.correlation, pair.winner, now)
            if let winner = pair.winner {
                pairEvents.append(PairEvent(t: t, a: pair.a, b: pair.b, correlation: pair.correlation, winner: winner))
            }
        }

        if now.timeIntervalSince(lastPublish) >= Self.publishInterval {
            lastPublish = now
            publish(elapsed: t, now: now)
        }
    }

    private func appendWaveform(samples: UnsafePointer<Float>, frames: Int, sampleRate: Double, channel: Int) {
        let binSamples = max(1, Int(sampleRate * Self.waveformBinSeconds))
        var index = 0
        while index + binSamples <= frames {
            var lo: Float = samples[index]
            var hi: Float = samples[index]
            for k in 1..<binSamples {
                let s = samples[index + k]
                if s < lo { lo = s }
                if s > hi { hi = s }
            }
            let clipped = max(abs(lo), abs(hi)) >= Self.clipLevel
            if clipped { clipCounts[channel] += 1 }
            waveHistory[channel].append(WaveBin(lo: lo, hi: hi, clipped: clipped))
            index += binSamples
        }
    }

    private func appendSpectra(buffers: [AVAudioPCMBuffer], count: Int, frames: Int) {
        guard let fft, frames >= Self.fftSize else { return }
        var offset = 0
        while offset + Self.fftSize <= frames {
            spectroHead = (spectroHead + 1) % Self.spectrogramColumns
            for channel in 0..<count {
                guard let data = buffers[channel].floatChannelData else { continue }
                let samples = UnsafePointer(data[0])
                computeSpectrum(samples: samples + offset, fft: fft, into: &lastSpectrum[channel])
                writeSpectrogramColumn(channel: channel, column: spectroHead, spectrum: lastSpectrum[channel])
            }
            offset += Self.fftHop
        }
    }

    /// One Hann-windowed FFT of `fftSize` samples reduced to log-spaced dB
    /// bins. 0 dB ~= a full-scale sine; clamped to the display floor.
    private func computeSpectrum(samples: UnsafePointer<Float>, fft: vDSP.FFT<DSPSplitComplex>, into spectrum: inout [Float]) {
        hannWindow.withUnsafeBufferPointer { window in
            for k in 0..<Self.fftSize {
                fftRealIn[k] = samples[k] * window[k]
                fftImagIn[k] = 0
            }
        }
        let input = DSPSplitComplex(realp: fftRealIn, imagp: fftImagIn)
        var output = DSPSplitComplex(realp: fftRealOut, imagp: fftImagOut)
        fft.forward(input: input, output: &output)

        // Full-scale Hann-windowed sine peaks at |X| ~= N/4 per side.
        let fullScalePower = Float(Self.fftSize * Self.fftSize) / 16
        for (bin, range) in binRanges.enumerated() {
            var power: Float = 0
            for k in range {
                power += fftRealOut[k] * fftRealOut[k] + fftImagOut[k] * fftImagOut[k]
            }
            power /= Float(range.count)
            let db = 10 * log10(max(power / fullScalePower, 1e-12))
            spectrum[bin] = max(Self.spectrogramFloorDB, min(0, db))
        }
    }

    private func rebuildBinTable(sampleRate: Double) {
        binTableRate = sampleRate
        let binHz = sampleRate / Double(Self.fftSize)
        let fMin = 60.0
        let fMax = min(12_000.0, sampleRate / 2 * 0.98)
        var ranges: [Range<Int>] = []
        var lastEnd = max(1, Int((fMin / binHz).rounded()))
        for k in 1...Self.spectrogramBins {
            let f = fMin * pow(fMax / fMin, Double(k) / Double(Self.spectrogramBins))
            let cap = Self.fftSize / 2 + 1
            var end = min(Int((f / binHz).rounded()), cap)
            if end <= lastEnd { end = min(lastEnd + 1, cap) }
            let start = min(lastEnd, end - 1)
            ranges.append(start..<end)
            lastEnd = end
        }
        binRanges = ranges
    }

    private func writeSpectrogramColumn(channel: Int, column: Int, spectrum: [Float]) {
        let cols = Self.spectrogramColumns
        let bins = Self.spectrogramBins
        spectroPixels[channel].withUnsafeMutableBufferPointer { pixels in
            for bin in 0..<bins {
                let normalized = (spectrum[bin] - Self.spectrogramFloorDB) / -Self.spectrogramFloorDB
                let entry = colormap[min(255, max(0, Int(normalized * 255)))]
                // Row 0 is the top of the image = highest frequency.
                let p = ((bins - 1 - bin) * cols + column) * 4
                pixels[p] = entry.r
                pixels[p + 1] = entry.g
                pixels[p + 2] = entry.b
                pixels[p + 3] = 255
            }
        }
    }

    // MARK: - Publishing (analysis queue -> main)

    private func publish(elapsed: TimeInterval, now: Date) {
        var cells = [[PairCell?]](
            repeating: [PairCell?](repeating: nil, count: channelCount),
            count: channelCount
        )
        for (key, held) in pairHold {
            let age = now.timeIntervalSince(held.at)
            guard age <= Self.pairHoldSeconds else { continue }
            let a = key >> 8, b = key & 0xFF
            guard a < channelCount, b < channelCount else { continue }
            let cell = PairCell(correlation: held.correlation, winner: held.winner, age: age)
            cells[a][b] = cell
            cells[b][a] = cell
        }

        let built = SignalSnapshot(
            channelCount: channelCount,
            sampleRate: currentSampleRate,
            elapsed: elapsed,
            gate: gateHistory.map { $0.ordered() },
            wave: waveHistory.map { $0.ordered() },
            spectrum: lastSpectrum,
            spectrogramImages: (0..<channelCount).map { makeSpectrogramImage(channel: $0) },
            pairs: cells,
            clipCounts: clipCounts,
            tunables: GateSettingsSnapshot.current()
        )
        DispatchQueue.main.async { self.snapshot = built }
    }

    private func makeSpectrogramImage(channel: Int) -> CGImage? {
        let cols = Self.spectrogramColumns
        let bins = Self.spectrogramBins
        let rowBytes = cols * 4
        guard spectroHead >= 0 else { return nil }
        // Unroll the column ring so x=0 is the oldest column.
        var unrolled = [UInt8](repeating: 0, count: spectroPixels[channel].count)
        let splitCol = (spectroHead + 1) % cols
        let tailBytes = (cols - splitCol) * 4
        spectroPixels[channel].withUnsafeBufferPointer { src in
            unrolled.withUnsafeMutableBufferPointer { dst in
                for row in 0..<bins {
                    let base = row * rowBytes
                    for i in 0..<tailBytes { dst[base + i] = src[base + splitCol * 4 + i] }
                    for i in 0..<(splitCol * 4) { dst[base + tailBytes + i] = src[base + i] }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(unrolled) as CFData) else { return nil }
        return CGImage(
            width: cols,
            height: bins,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func pairKey(_ a: Int, _ b: Int) -> Int {
        (min(a, b) << 8) | max(a, b)
    }

    private static func makeColormap() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        // Viridis control points; linearly interpolated to 256 entries.
        let stops: [(Float, Float, Float)] = [
            (0x44, 0x01, 0x54), (0x3B, 0x52, 0x8B), (0x21, 0x91, 0x8C),
            (0x5E, 0xC9, 0x62), (0xFD, 0xE7, 0x25),
        ].map { (Float($0.0), Float($0.1), Float($0.2)) }
        return (0..<256).map { i in
            let position = Float(i) / 255 * Float(stops.count - 1)
            let lower = min(stops.count - 2, Int(position))
            let f = position - Float(lower)
            let a = stops[lower], b = stops[lower + 1]
            return (UInt8(a.0 + (b.0 - a.0) * f),
                    UInt8(a.1 + (b.1 - a.1) * f),
                    UInt8(a.2 + (b.2 - a.2) * f))
        }
    }
}

// MARK: - Snapshot types

/// One gate decision sample (per channel, per 200 ms buffer).
struct GatePoint {
    var t: TimeInterval
    var rms: Float
    var noiseFloor: Float
    var threshold: Float
    var voiced: Bool
    var pass: Bool
    var bleed: Bool
}

/// One 10 ms waveform envelope bin.
struct WaveBin {
    var lo: Float
    var hi: Float
    var clipped: Bool
}

/// Held pair-correlation state for the matrix display.
struct PairCell {
    var correlation: Float
    var winner: Int?
    var age: TimeInterval
}

/// A bleed-suppression event (pair correlated above threshold).
struct PairEvent {
    var t: TimeInterval
    var a: Int
    var b: Int
    var correlation: Float
    var winner: Int
}

/// The gate tunables currently in effect (persisted settings are the source
/// of truth; AppModel applies the same values to the live gate).
struct GateSettingsSnapshot: Codable {
    var enabled: Bool
    var minimumVoiceThreshold: Float
    var snrFactor: Float
    var bleedCorrelation: Float
    var takeoverMargin: Float
    var hangover: Double

    static func current() -> GateSettingsSnapshot {
        GateSettingsSnapshot(
            enabled: AppSettings.noiseGateEnabled,
            minimumVoiceThreshold: AppSettings.vadThreshold,
            snrFactor: AppSettings.snrFactor,
            bleedCorrelation: AppSettings.bleedCorrelation,
            takeoverMargin: AppSettings.takeoverMargin,
            hangover: AppSettings.gateHangover
        )
    }
}

/// Everything the Signal tab draws, as one immutable value.
struct SignalSnapshot {
    var channelCount: Int
    var sampleRate: Double
    var elapsed: TimeInterval
    var gate: [[GatePoint]]
    var wave: [[WaveBin]]
    var spectrum: [[Float]]
    var spectrogramImages: [CGImage?]
    var pairs: [[PairCell?]]
    var clipCounts: [Int]
    var tunables: GateSettingsSnapshot

    static let empty = SignalSnapshot(
        channelCount: 0,
        sampleRate: 48_000,
        elapsed: 0,
        gate: [],
        wave: [],
        spectrum: [],
        spectrogramImages: [],
        pairs: [],
        clipCounts: [],
        tunables: GateSettingsSnapshot.current()
    )
}

/// Fixed-capacity append-only ring.
struct RingBuffer<Element> {
    private var storage: [Element] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Contents oldest-first.
    func ordered() -> [Element] {
        guard storage.count == capacity, head > 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }
}
