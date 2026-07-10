import Foundation
import os

/// In-app diagnostic log. Everything important (route changes, WebSocket
/// events, errors) lands here so it can be inspected on-device in
/// DiagnosticsView — there is no attached debugger in Swift Playgrounds.
final class Log: ObservableObject {
    static let shared = Log()

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERR "
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    private static let osLog = Logger(subsystem: "translator", category: "app")
    private let maxEntries = 600

    static func info(_ message: String) { shared.append(.info, message) }
    static func warn(_ message: String) { shared.append(.warn, message) }
    static func error(_ message: String) { shared.append(.error, message) }

    private func append(_ level: Level, _ message: String) {
        switch level {
        case .info: Self.osLog.info("\(message)")
        case .warn: Self.osLog.warning("\(message)")
        case .error: Self.osLog.error("\(message)")
        }
        DispatchQueue.main.async {
            self.entries.append(Entry(date: Date(), level: level, message: message))
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    private static let exportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Full log as plain text, oldest first — for copy/share out of the app.
    /// Called from view bodies, so no per-call formatter allocation.
    func exportText() -> String {
        entries
            .map { "\(Self.exportFormatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}
