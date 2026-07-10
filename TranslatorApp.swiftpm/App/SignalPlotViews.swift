import SwiftUI

/// Canvas-based plots for the Signal tab. Every view draws from immutable
/// snapshot values — no locks, no observation of its own.

// MARK: - Gate timeline

/// Scrolling per-channel gate history: RMS level vs. tracked noise floor vs.
/// effective threshold on a dB scale, with green shading where the gate
/// passed audio and red triangles where bleed rejection suppressed it.
struct GateTimelineView: View {
    let points: [GatePoint]
    let elapsed: TimeInterval
    let color: Color

    private static let floorDB: Double = -60
    private static let bufferSeconds = 0.2

    var body: some View {
        Canvas { context, size in
            let window = SignalAnalyzer.gateWindowSeconds
            let start = elapsed - window

            func x(_ t: TimeInterval) -> CGFloat {
                CGFloat((t - start) / window) * size.width
            }
            func y(_ value: Float) -> CGFloat {
                let db = 20 * log10(Double(max(1e-5, value)))
                let clamped = min(0, max(Self.floorDB, db))
                return size.height * CGFloat(1 - (clamped - Self.floorDB) / -Self.floorDB)
            }

            // dB gridlines every 20 dB, recessive.
            for db in stride(from: Self.floorDB + 20, through: -20, by: 20) {
                let gy = size.height * CGFloat(1 - (db - Self.floorDB) / -Self.floorDB)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: gy))
                grid.addLine(to: CGPoint(x: size.width, y: gy))
                context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }

            for point in points where point.t >= start {
                let x1 = x(point.t)
                let x0 = max(0, x(point.t - Self.bufferSeconds))
                if point.pass {
                    context.fill(
                        Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                        with: .color(.green.opacity(0.13))
                    )
                }
                if point.bleed {
                    var triangle = Path()
                    let cx = (x0 + x1) / 2
                    triangle.move(to: CGPoint(x: cx - 4, y: 2))
                    triangle.addLine(to: CGPoint(x: cx + 4, y: 2))
                    triangle.addLine(to: CGPoint(x: cx, y: 10))
                    triangle.closeSubpath()
                    context.fill(triangle, with: .color(.red))
                }
            }

            func line(_ value: (GatePoint) -> Float) -> Path {
                var path = Path()
                var started = false
                for point in points where point.t >= start {
                    let pt = CGPoint(x: x(point.t), y: y(value(point)))
                    if started {
                        path.addLine(to: pt)
                    } else {
                        path.move(to: pt)
                        started = true
                    }
                }
                return path
            }

            context.stroke(
                line { $0.noiseFloor },
                with: .color(.secondary),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
            context.stroke(
                line { $0.threshold },
                with: .color(.primary.opacity(0.6)),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
            )
            context.stroke(line { $0.rms }, with: .color(color), lineWidth: 2)
        }
    }
}

// MARK: - Waveform envelope

/// 10 ms min/max envelope; clipped bins drawn red.
struct WaveformView: View {
    let bins: [WaveBin]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
            let binWidth = size.width / CGFloat(bins.count)
            let mid = size.height / 2
            var centerline = Path()
            centerline.move(to: CGPoint(x: 0, y: mid))
            centerline.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(centerline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

            var normal = Path()
            var clipped = Path()
            for (index, bin) in bins.enumerated() {
                let x = CGFloat(index) * binWidth
                let yHi = mid - CGFloat(min(1, max(-1, bin.hi))) * (mid - 1)
                let yLo = mid - CGFloat(min(1, max(-1, bin.lo))) * (mid - 1)
                let rect = CGRect(
                    x: x,
                    y: min(yHi, yLo),
                    width: max(binWidth, 0.5),
                    height: max(1, abs(yLo - yHi))
                )
                if bin.clipped {
                    clipped.addRect(rect)
                } else {
                    normal.addRect(rect)
                }
            }
            context.fill(normal, with: .color(color.opacity(0.75)))
            context.fill(clipped, with: .color(.red))
        }
    }
}

// MARK: - Instantaneous spectrum

/// Latest FFT column: 96 log-spaced bins, dB magnitude.
struct SpectrumView: View {
    let bins: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            let floor = SignalAnalyzer.spectrogramFloorDB
            var path = Path()
            for (index, db) in bins.enumerated() {
                let x = CGFloat(index) / CGFloat(bins.count - 1) * size.width
                let yNorm = (db - floor) / -floor
                let point = CGPoint(x: x, y: size.height * CGFloat(1 - yNorm))
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.15)))
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

// MARK: - Spectrogram

/// Scrolling heatmap of the log-spaced spectrum (newest column at the right).
struct SpectrogramView: View {
    let image: CGImage?

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if let image {
                context.draw(
                    Image(decorative: image, scale: 1).interpolation(.none),
                    in: rect
                )
            } else {
                context.fill(Path(rect), with: .color(.secondary.opacity(0.1)))
            }
            // Frequency ticks on the log axis (60 Hz ... 12 kHz).
            for (freq, label) in [(100.0, "100"), (1000.0, "1k"), (10_000.0, "10k")] {
                let yNorm = log(freq / 60) / log(12_000 / 60)
                let y = size.height * CGFloat(1 - yNorm)
                var tick = Path()
                tick.move(to: CGPoint(x: 0, y: y))
                tick.addLine(to: CGPoint(x: 5, y: y))
                context.stroke(tick, with: .color(.white.opacity(0.8)), lineWidth: 1)
                context.draw(
                    Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.8)),
                    at: CGPoint(x: 8, y: y),
                    anchor: .leading
                )
            }
        }
    }
}

// MARK: - Correlation matrix

/// Live pairwise peak correlations. A pair is only measured while both
/// channels are voiced; cells fade as their reading ages out.
struct CorrelationMatrixView: View {
    let pairs: [[PairCell?]]
    let lanes: [SpeakerLane]
    let threshold: Float

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(lanes) { lane in
                    header(lane)
                }
            }
            ForEach(Array(lanes.enumerated()), id: \.element.id) { row, lane in
                GridRow {
                    header(lane)
                    ForEach(Array(lanes.enumerated()), id: \.element.id) { col, _ in
                        cell(row: row, col: col)
                    }
                }
            }
        }
    }

    private func header(_ lane: SpeakerLane) -> some View {
        HStack(spacing: 4) {
            Circle().fill(lane.color).frame(width: 8, height: 8)
            Text(lane.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cell(row: Int, col: Int) -> some View {
        if row == col {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 44)
        } else if row < pairs.count, col < pairs[row].count, let pair = pairs[row][col] {
            let over = pair.correlation >= threshold
            let intensity = Double(min(1, max(0, pair.correlation)))
            VStack(spacing: 1) {
                Text(String(format: "%.2f", pair.correlation))
                    .font(.caption.monospacedDigit().bold())
                if over, let winner = pair.winner, winner < lanes.count {
                    Text("\(lanes[winner].name) wins")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.teal.opacity(0.1 + 0.5 * intensity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(over ? Color.red : Color.clear, lineWidth: 2)
            )
            .opacity(1 - pair.age / SignalAnalyzer.pairHoldSeconds * 0.6)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
                .frame(height: 44)
                .overlay(
                    Text("–")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                )
        }
    }
}
