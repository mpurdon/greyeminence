import Foundation
import os.log

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

    private static let osLog = OSLog(subsystem: "com.greyeminence.app", category: "GreyEminence")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let systemLogURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GreyEminence", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("system.log")
    }()

    private init() {}

    func log(
        _ message: String,
        category: LogEntry.Category = .general,
        level: LogEntry.Level = .info,
        detail: String? = nil,
        meetingID: UUID? = nil
    ) {
        let entry = LogEntry(category: category, level: level, message: message, detail: detail)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let osType: OSLogType = level == .error ? .error : level == .warning ? .default : .info
        os_log("%{public}s [%{public}s] %{public}s", log: LogManager.osLog, type: osType, category.rawValue, level.rawValue, message)

        let line = formatLine(message: message, category: category, level: level, detail: detail)
        if let meetingID {
            appendToMeetingLog(meetingID: meetingID, line: line)
        }
        appendToFile(url: systemLogURL, line: line)
    }

    /// Nonisolated entry point for actor-isolated callers.
    nonisolated static func send(
        _ message: String,
        category: LogEntry.Category = .general,
        level: LogEntry.Level = .info,
        detail: String? = nil,
        meetingID: UUID? = nil
    ) {
        Task { @MainActor in
            LogManager.shared.log(message, category: category, level: level, detail: detail, meetingID: meetingID)
        }
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - Private

    private func formatLine(message: String, category: LogEntry.Category, level: LogEntry.Level, detail: String?) -> String {
        let ts = LogManager.dateFormatter.string(from: Date())
        var line = "[\(ts)] [\(category.rawValue)] [\(level.rawValue)] \(message)"
        if let detail { line += "\n  \(detail)" }
        return line + "\n"
    }

    private func appendToMeetingLog(meetingID: UUID, line: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GreyEminence/Recordings/\(meetingID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("meeting.log")
        appendToFile(url: url, line: line)
    }

    private func appendToFile(url: URL, line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
