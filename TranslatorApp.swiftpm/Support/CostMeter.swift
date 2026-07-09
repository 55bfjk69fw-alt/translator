import Foundation

/// Tracks connected session-minutes and estimates spend.
/// gpt-realtime-translate is billed per minute of session audio; the exact
/// billing basis (wall-clock vs active speech) is unconfirmed, so this meter
/// assumes the conservative wall-clock interpretation.
final class CostMeter {
    static let dollarsPerSessionMinute = 0.034

    private var openSessions = 0
    private var accumulatedSeconds: Double = 0
    private var lastTick: Date?
    private let lock = NSLock()

    func sessionOpened() {
        lock.lock(); defer { lock.unlock() }
        tickLocked()
        openSessions += 1
    }

    func sessionClosed() {
        lock.lock(); defer { lock.unlock() }
        tickLocked()
        openSessions = max(0, openSessions - 1)
    }

    /// Total estimated dollars so far.
    var estimatedDollars: Double {
        lock.lock(); defer { lock.unlock() }
        tickLocked()
        return accumulatedSeconds / 60.0 * Self.dollarsPerSessionMinute
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        accumulatedSeconds = 0
        lastTick = openSessions > 0 ? Date() : nil
    }

    private func tickLocked() {
        let now = Date()
        if let last = lastTick, openSessions > 0 {
            accumulatedSeconds += now.timeIntervalSince(last) * Double(openSessions)
        }
        lastTick = now
    }
}
