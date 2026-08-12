import Foundation
import Observation
import os

/// Severity. `Comparable` so the Logs view can apply a min-level filter.
enum LogLevel: String, Comparable, Sendable {
    case debug, info, warning, error

    private var rank: Int {
        switch self {
        case .debug:   0
        case .info:    1
        case .warning: 2
        case .error:   3
        }
    }
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// One line in the in-app log. `id` is a monotonic counter so SwiftUI's
/// ForEach has a stable identity even if two entries land on the same Date.
struct LogEntry: Identifiable, Sendable {
    let id: UInt64
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
}

/// Process-wide log buffer. UI observes via @Observable; mutations happen on
/// the main actor. Capped at `cap` entries — when full we drop the oldest
/// chunk so the head/tail semantics stay simple.
@MainActor
@Observable
final class LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
    private var nextId: UInt64 = 0
    private let cap = 5000

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    func clear() {
        entries.removeAll()
        nextId = 0
    }

    /// Used by `Logger` to mint stable IDs even when multiple Tasks race to
    /// append — main-actor isolation makes this trivially atomic.
    func mintID() -> UInt64 {
        nextId += 1
        return nextId
    }
}

/// Per-category log handle. Created statically as `Log.<category>`. Calls are
/// safe from any thread; appends hop to the main actor. Each line is also
/// mirrored to `os_log` so it appears in Console.app and survives a crash.
nonisolated struct Logger: Sendable {
    let category: String

    private static let osLogs: [String: OSLog] = {
        let subsystem = Bundle.main.bundleIdentifier ?? "studio.rischio.mypod"
        return [
            "ui":       OSLog(subsystem: subsystem, category: "ui"),
            "device":   OSLog(subsystem: subsystem, category: "device"),
            "library":  OSLog(subsystem: subsystem, category: "library"),
            "playlist": OSLog(subsystem: subsystem, category: "playlist"),
            "convert":  OSLog(subsystem: subsystem, category: "convert"),
            "sync":     OSLog(subsystem: subsystem, category: "sync"),
            "ipod":     OSLog(subsystem: subsystem, category: "ipod"),
            "artwork":  OSLog(subsystem: subsystem, category: "artwork"),
        ]
    }()

    func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    func warning(_ message: @autoclosure () -> String) { emit(.warning, message()) }
    func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private func emit(_ level: LogLevel, _ message: String) {
        // Mirror to os_log immediately — thread-safe, available even if the
        // main actor is busy or the app crashes before flush.
        if let osLog = Self.osLogs[category] {
            let type: OSLogType = switch level {
                case .debug:   .debug
                case .info:    .info
                case .warning: .default
                case .error:   .error
            }
            os_log("%{public}@", log: osLog, type: type, message)
        }
        // Also dump to stderr so terminal launches see it without launching Console.app.
        FileHandle.standardError.write(Data("[\(level.rawValue) \(category)] \(message)\n".utf8))

        let cat = category
        let lvl = level
        Task { @MainActor in
            let store = LogStore.shared
            let entry = LogEntry(
                id: store.mintID(),
                timestamp: Date(),
                level: lvl,
                category: cat,
                message: message
            )
            store.append(entry)
        }
    }
}

/// Static category handles. Add new ones here and to `Logger.osLogs` /
/// `LogsView.categories` when introducing a new logging surface.
nonisolated enum Log {
    static let ui       = Logger(category: "ui")
    static let device   = Logger(category: "device")
    static let library  = Logger(category: "library")
    static let playlist = Logger(category: "playlist")
    static let convert  = Logger(category: "convert")
    static let sync     = Logger(category: "sync")
    static let ipod     = Logger(category: "ipod")
    static let artwork  = Logger(category: "artwork")
}
