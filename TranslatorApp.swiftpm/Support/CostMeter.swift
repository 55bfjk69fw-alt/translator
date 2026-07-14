import Foundation

/// Accumulates the conversation's estimated cost in dollars.
///
/// Pricing lives with the engines, not here: each LaneEngine converts its
/// own billed units to dollars (RealtimeLaneEngine holds the realtime
/// per-minute rates and their dashboard-derivation notes; Apple cascade
/// engines never report cost) and this meter just sums the deltas. The
/// underlying realtime measurement is unchanged: each client reports the
/// max of the server's session clock and the audio actually appended,
/// which counts the pre-open queue flush and the post-close drain and
/// ignores engine stalls.
final class CostMeter {
    private var dollars: Double = 0
    private let lock = NSLock()

    /// Thread-safe; engines report increments from their own queues —
    /// including through an idle-close drain, which is why this is never
    /// identity-guarded upstream.
    func addDollars(_ amount: Double) {
        guard amount > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        dollars += amount
    }

    /// Total estimated dollars so far.
    var estimatedDollars: Double {
        lock.lock(); defer { lock.unlock() }
        return dollars
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        dollars = 0
    }
}
