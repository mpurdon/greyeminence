import Foundation

extension String {
    /// This string made safe to use as a filename: characters illegal on the
    /// filesystems the app writes to (Finder, iCloud, Obsidian vaults) are
    /// removed, and the result is bounded so a long meeting title can't
    /// produce a path the OS rejects.
    ///
    /// `replacements` maps a character to what it becomes *instead of* being
    /// dropped — e.g. `:` → `.` so "3:42 PM" reads as "3.42 PM" rather than
    /// "342 PM". Anything in the illegal set without a replacement is removed.
    func sanitizedForFilename(maxLength: Int = 200, replacements: [Character: Character] = [:]) -> String {
        let illegal = Set("/:\\?\"<>|*")
        let mapped = String(map { ch in
            if let replacement = replacements[ch] { return replacement }
            return illegal.contains(ch) ? nil : ch
        }.compactMap { $0 })
        return String(mapped.trimmingCharacters(in: .whitespaces).prefix(maxLength))
    }
}

/// Names for exported files, the same shape everywhere.
enum ExportFilename {
    /// "Bulk Invoice Export — 2026-09-23 (refinement).md"
    static func suggested(title: String, date: Date, suffix: String, fileExtension: String) -> String {
        let calendar = Calendar.current
        let day = String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date)
        )
        return "\(title) — \(day) (\(suffix))".sanitizedForFilename() + ".\(fileExtension)"
    }
}
