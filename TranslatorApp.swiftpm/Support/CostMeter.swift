import Foundation

/// Accumulates billed audio seconds reported by the realtime clients and
/// converts them to dollars.
///
/// Each realtime session bills two lines on the same "realtime audio
/// duration": gpt-realtime-translate at $0.034 per minute, plus
/// gpt-realtime-whisper source transcription (which every session.update
/// requests — see SessionConfig) at roughly half that. Each client measures
/// the billed duration directly as the max of two signals:
/// the server's own session clock (`elapsed_ms` on delta events, including
/// the ~200 ms heartbeat frames) and the duration of input audio actually
/// appended (bytes at 24 kHz PCM16 mono). This replaces the old
/// wall-clock-while-open estimate, which overcounted engine stalls (socket
/// open, nothing streamed) and undercounted the pre-open queued-audio flush
/// and the post-close server drain.
final class CostMeter {
    static let dollarsPerSessionMinute = 0.034
    /// gpt-realtime-whisper source transcription, billed on the same session
    /// minutes as translation. Derived from the owner's 2026-07-12 dashboard
    /// ($8.40 whisper vs $17.00 translate on identical billed minutes);
    /// OpenAI's published per-minute price for gpt-realtime-whisper inside
    /// translation sessions was not verifiable from this codebase — update
    /// when published, like the translate rate above.
    ///
    /// Calibration caveat: that dashboard predates the send-path change that
    /// pauses appends while the gate is closed. On main, appended minutes
    /// equalled session-clock minutes, so the two lines were proportional by
    /// construction; if the pause regime makes them diverge (translate on
    /// the session clock, whisper on appended audio), a single combined rate
    /// can't represent both — re-derive this ratio from the first
    /// post-merge dashboard alongside issue #1's billing verification.
    static let transcriptionDollarsPerSessionMinute = 0.0168
    static var combinedDollarsPerSessionMinute: Double {
        dollarsPerSessionMinute + transcriptionDollarsPerSessionMinute
    }

    private var billedSeconds: Double = 0
    private let lock = NSLock()

    /// Thread-safe; clients report increments from their socket queues.
    /// Negative values are corrections — audio counted at hand-off that
    /// died with its connection before reaching the server is never billed
    /// there, so the client retracts it. Clamped at zero.
    func addBilledSeconds(_ seconds: Double) {
        guard seconds != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        billedSeconds = max(0, billedSeconds + seconds)
    }

    /// Total estimated dollars so far.
    var estimatedDollars: Double {
        lock.lock(); defer { lock.unlock() }
        return billedSeconds / 60.0 * Self.combinedDollarsPerSessionMinute
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        billedSeconds = 0
    }
}
