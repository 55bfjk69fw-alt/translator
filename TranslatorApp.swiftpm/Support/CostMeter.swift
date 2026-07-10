import Foundation

/// Accumulates billed audio seconds reported by the realtime clients and
/// converts them to dollars.
///
/// gpt-realtime-translate bills $0.034 per minute of "realtime audio
/// duration". Each client measures that directly as the max of two signals:
/// the server's own session clock (`elapsed_ms` on delta events, including
/// the ~200 ms heartbeat frames) and the duration of input audio actually
/// appended (bytes at 24 kHz PCM16 mono). This replaces the old
/// wall-clock-while-open estimate, which overcounted engine stalls (socket
/// open, nothing streamed) and undercounted the pre-open queued-audio flush
/// and the post-close server drain.
final class CostMeter {
    static let dollarsPerSessionMinute = 0.034

    private var billedSeconds: Double = 0
    /// Directly-estimated dollars from the staged pipeline (translation
    /// tokens, TTS characters). On-device stages report nothing, so an
    /// all-on-device staged conversation correctly reads $0.00.
    private var directDollars: Double = 0
    private let lock = NSLock()

    /// Thread-safe; clients report increments from their socket queues.
    func addBilledSeconds(_ seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        billedSeconds += seconds
    }

    /// Thread-safe; staged stages report token/character-based estimates.
    func addDollars(_ dollars: Double) {
        guard dollars > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        directDollars += dollars
    }

    /// Total estimated dollars so far.
    var estimatedDollars: Double {
        lock.lock(); defer { lock.unlock() }
        return billedSeconds / 60.0 * Self.dollarsPerSessionMinute + directDollars
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        billedSeconds = 0
        directDollars = 0
    }
}
