import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let category: Category
    let level: Level
    let message: String
    let detail: String?

    enum Category: String, CaseIterable, Identifiable {
        case audio
        case transcription
        case ai
        case obsidian
        case general

        var id: String { rawValue }
    }

    enum Level: String, CaseIterable, Identifiable {
        case info
        case warning
        case error

        var id: String { rawValue }
    }
}

@Observable
@MainActor
final class LogManager {
    static let shared = LogManager()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000

    private init() {}

    func log(_ message: String, category: LogEntry.Category = .general, level: LogEntry.Level = .info, detail: String? = nil) {
        let entry = LogEntry(category: category, level: level, message: message, detail: detail)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Nonisolated entry point for actor-isolated callers.
    /// Access as `LogManager.send(...)` — avoids needing MainActor access to `.shared`.
    nonisolated static func send(_ message: String, category: LogEntry.Category = .general, level: LogEntry.Level = .info, detail: String? = nil) {
        Task { @MainActor in
            LogManager.shared.log(message, category: category, level: level, detail: detail)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
