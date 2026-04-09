import Foundation

/// Stable keys for every editable prompt. Values are used as filenames under
/// `AppSupport/GreyEminence/prompts/<rawValue>.md`.
enum PromptKey: String, CaseIterable, Identifiable, Sendable {
    case meetingSystem        = "meeting.system"
    case meetingInitial       = "meeting.initial"
    case meetingRolling       = "meeting.rolling"
    case meetingFinal         = "meeting.final"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meetingSystem:  "Meeting — System Prompt"
        case .meetingInitial: "Meeting — Initial Analysis"
        case .meetingRolling: "Meeting — Rolling Analysis"
        case .meetingFinal:   "Meeting — Final Cleanup"
        }
    }

    /// Placeholders the prompt supports. `PromptStore.render` substitutes `{{key}}`
    /// with the provided value. Empty means the prompt takes no arguments.
    var placeholders: [String] {
        switch self {
        case .meetingSystem:
            []
        case .meetingInitial:
            ["transcript"]
        case .meetingRolling:
            ["previousSummary", "previousActionItems", "previousFollowUps", "previousTopics", "newTranscript"]
        case .meetingFinal:
            ["fullTranscript", "currentSummary", "currentActionItems", "currentFollowUps", "currentTopics"]
        }
    }
}

/// Runtime-editable prompt storage. Reads from disk lazily and caches in memory.
/// When no override exists for a key, callers fall back to the hardcoded defaults
/// in `AIPromptTemplates`. Overrides are only *loaded* (not written) by callers;
/// writing is done via `set(_:to:)` from the developer settings UI.
///
/// Thread-safety: all state is protected by an internal lock. The store is a
/// reference type (class, not actor) because it needs to be accessed synchronously
/// from the AI service path without suspension.
final class PromptStore: @unchecked Sendable {
    static let shared = PromptStore()

    private let lock = NSLock()
    private var cache: [PromptKey: String] = [:]
    private var loaded: Bool = false

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GreyEminence", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {}

    /// Returns the override for `key` if present, otherwise `defaultValue`.
    /// `defaultValue` is an `@autoclosure` so the (sometimes large) hardcoded
    /// strings aren't built unnecessarily.
    func get(_ key: PromptKey, default defaultValue: @autoclosure () -> String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if !loaded {
            loadFromDiskLocked()
        }
        if let override = cache[key], !override.isEmpty {
            return override
        }
        return defaultValue()
    }

    /// Returns the raw override if present, or nil if the user has not overridden
    /// this key. Used by the editor to decide whether to show "custom" state.
    func override(for key: PromptKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded { loadFromDiskLocked() }
        return cache[key]
    }

    /// Write an override for a key. Passing an empty string removes the override.
    func set(_ key: PromptKey, to value: String) {
        lock.lock()
        defer { lock.unlock() }
        if !loaded { loadFromDiskLocked() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cache.removeValue(forKey: key)
            let url = directory.appendingPathComponent("\(key.rawValue).md")
            try? FileManager.default.removeItem(at: url)
            LogManager.send("Prompt override cleared: \(key.rawValue)", category: .ai)
        } else {
            cache[key] = value
            let url = directory.appendingPathComponent("\(key.rawValue).md")
            do {
                try value.write(to: url, atomically: true, encoding: .utf8)
                LogManager.send("Prompt override saved: \(key.rawValue) (\(value.count) chars)", category: .ai)
            } catch {
                LogManager.send("Prompt override save failed (\(key.rawValue)): \(error.localizedDescription)", category: .ai, level: .error)
            }
        }
    }

    /// Remove all overrides. Useful for the "Restore all defaults" button.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        for key in PromptKey.allCases {
            let url = directory.appendingPathComponent("\(key.rawValue).md")
            try? FileManager.default.removeItem(at: url)
        }
        LogManager.send("All prompt overrides cleared", category: .ai)
    }

    /// Substitute `{{placeholder}}` tokens in `template` with values from `values`.
    /// Any placeholder not present in `values` is left as-is so the user can see
    /// what they forgot to provide. This is called by `AIPromptTemplates` after
    /// fetching the (possibly overridden) template text.
    static func render(_ template: String, values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    // MARK: - Private

    private func loadFromDiskLocked() {
        loaded = true
        for key in PromptKey.allCases {
            let url = directory.appendingPathComponent("\(key.rawValue).md")
            guard FileManager.default.fileExists(atPath: url.path),
                  let contents = try? String(contentsOf: url, encoding: .utf8),
                  !contents.isEmpty else {
                continue
            }
            cache[key] = contents
        }
    }
}
