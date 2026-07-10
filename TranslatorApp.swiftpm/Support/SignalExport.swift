import Foundation

/// Serializes the Signal tab's frozen analysis window as pretty-printed JSON
/// for sharing/inspection. The spectrogram is deliberately excluded (large,
/// and reproducible from the audio + settings); the gate timeline and 10 ms
/// waveform envelope carry the diagnostic content.
enum SignalExport {

    struct Payload: Codable {
        var capturedAt: String
        var sampleRate: Double
        var channelCount: Int
        var gateSettings: GateSettingsSnapshot
        var channels: [Channel]
        var bleedEvents: [Event]
    }

    struct Channel: Codable {
        var index: Int
        var name: String
        var stats: Stats
        var gateTimeline: [TimelinePoint]
        var waveEnvelope: Envelope
    }

    struct Stats: Codable {
        var rmsMean: Float
        var rmsPeak: Float
        var noiseFloorNow: Float
        var thresholdNow: Float
        var voicedPercent: Float
        var passPercent: Float
        var bleedBuffers: Int
        var clipCount: Int
    }

    struct TimelinePoint: Codable {
        var t: Double
        var rms: Float
        var floor: Float
        var thr: Float
        var voiced: Bool
        var pass: Bool
        var bleed: Bool
    }

    struct Envelope: Codable {
        var binSeconds: Double
        var lo: [Float]
        var hi: [Float]
    }

    struct Event: Codable {
        var t: Double
        var a: Int
        var b: Int
        var corr: Float
        var winner: Int
    }

    static func json(
        channelNames: [String],
        sampleRate: Double,
        settings: GateSettingsSnapshot,
        gateHistory: [[GatePoint]],
        waveHistory: [[WaveBin]],
        clipCounts: [Int],
        pairEvents: [PairEvent]
    ) -> String {
        let channels = gateHistory.indices.map { index -> Channel in
            let gate = gateHistory[index]
            let wave = index < waveHistory.count ? waveHistory[index] : []
            let rmsValues = gate.map(\.rms)
            let voicedCount = gate.filter(\.voiced).count
            let passCount = gate.filter(\.pass).count
            let percent = { (count: Int) -> Float in
                gate.isEmpty ? 0 : Float(count) / Float(gate.count) * 100
            }
            return Channel(
                index: index,
                name: index < channelNames.count ? channelNames[index] : "Channel \(index + 1)",
                stats: Stats(
                    rmsMean: rmsValues.isEmpty ? 0 : rmsValues.reduce(0, +) / Float(rmsValues.count),
                    rmsPeak: rmsValues.max() ?? 0,
                    noiseFloorNow: gate.last?.noiseFloor ?? 0,
                    thresholdNow: gate.last?.threshold ?? 0,
                    voicedPercent: percent(voicedCount),
                    passPercent: percent(passCount),
                    bleedBuffers: gate.filter(\.bleed).count,
                    clipCount: index < clipCounts.count ? clipCounts[index] : 0
                ),
                gateTimeline: gate.map {
                    TimelinePoint(t: $0.t, rms: $0.rms, floor: $0.noiseFloor, thr: $0.threshold,
                                  voiced: $0.voiced, pass: $0.pass, bleed: $0.bleed)
                },
                waveEnvelope: Envelope(
                    binSeconds: SignalAnalyzer.waveformBinSeconds,
                    lo: wave.map(\.lo),
                    hi: wave.map(\.hi)
                )
            )
        }
        let payload = Payload(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            sampleRate: sampleRate,
            channelCount: gateHistory.count,
            gateSettings: settings,
            channels: channels,
            bleedEvents: pairEvents.map {
                Event(t: $0.t, a: $0.a, b: $0.b, corr: $0.correlation, winner: $0.winner)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"encoding failed\"}"
        }
        return text
    }
}
