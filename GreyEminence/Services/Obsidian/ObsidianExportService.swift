import Foundation

enum ObsidianExportService {
    enum ExportError: LocalizedError {
        case noVaultConfigured
        case vaultAccessDenied
        case writeFailure(Error)

        var errorDescription: String? {
            switch self {
            case .noVaultConfigured: "No Obsidian vault configured"
            case .vaultAccessDenied: "Cannot access Obsidian vault — re-select in Settings"
            case .writeFailure(let error): "Failed to write file: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    static func export(meeting: Meeting) throws -> URL {
        let defaults = UserDefaults.standard
        let vaultPath = defaults.string(forKey: "obsidianVaultPath") ?? ""
        guard !vaultPath.isEmpty else { throw ExportError.noVaultConfigured }

        let subfolder = defaults.string(forKey: "obsidianMeetingsFolder") ?? "Meetings"
        let includeTranscript = defaults.bool(forKey: "obsidianIncludeTranscript")
        let includeActionItems = defaults.bool(forKey: "obsidianIncludeActionItems")
        let includeWikilinks = defaults.bool(forKey: "obsidianIncludeWikilinks")

        // Activate security-scoped bookmark
        ObsidianSettingsView.restoreVaultAccess()

        let vaultURL = URL(fileURLWithPath: vaultPath)
        let folderURL = vaultURL.appendingPathComponent(subfolder)

        // Create subfolder if needed
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw ExportError.vaultAccessDenied
        }

        let insight = meeting.latestInsight
        let markdown = buildMarkdown(
            meeting: meeting,
            insight: insight,
            includeTranscript: includeTranscript,
            includeActionItems: includeActionItems,
            includeWikilinks: includeWikilinks
        )

        let dateString = formatDate(meeting.date)
        let filename = sanitizeFilename("\(meeting.title) — \(dateString).md")
        let fileURL = folderURL.appendingPathComponent(filename)

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.writeFailure(error)
        }

        meeting.isExportedToObsidian = true
        return fileURL
    }

    // MARK: - Markdown Generation

    @MainActor
    private static func buildMarkdown(
        meeting: Meeting,
        insight: MeetingInsight?,
        includeTranscript: Bool,
        includeActionItems: Bool,
        includeWikilinks: Bool
    ) -> String {
        var lines: [String] = []

        // YAML frontmatter
        let dateString = formatDate(meeting.date)
        let tags = (insight?.topics ?? []).map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }
        let tagList = (["meeting"] + tags).map { "\"\($0)\"" }.joined(separator: ", ")

        lines.append("---")
        lines.append("title: \(meeting.title)")
        lines.append("date: \(dateString)")
        lines.append("duration: \(meeting.formattedDuration)")
        lines.append("tags: [\(tagList)]")
        let attendeeNames = meeting.attendees.sorted { $0.name < $1.name }.map(\.name)
        if !attendeeNames.isEmpty {
            let attendeeList = attendeeNames.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("attendees: [\(attendeeList)]")
        }
        lines.append("---")
        lines.append("")

        // Summary
        if let summary = insight?.summary, !summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        // Action Items
        if includeActionItems && !meeting.actionItems.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            for item in meeting.actionItems {
                let checkbox = item.isCompleted ? "- [x]" : "- [ ]"
                let assignee = item.displayAssignee.map { " @\($0)" } ?? ""
                lines.append("\(checkbox) \(item.text)\(assignee)")
            }
            lines.append("")
        }

        // Follow-Up Questions
        if let questions = insight?.followUpQuestions, !questions.isEmpty {
            lines.append("## Follow-Up Questions")
            lines.append("")
            for question in questions {
                lines.append("- \(question)")
            }
            lines.append("")
        }

        // Topics as wikilinks
        if includeWikilinks, let topics = insight?.topics, !topics.isEmpty {
            lines.append("## Topics")
            lines.append("")
            lines.append(topics.map { "[[\($0)]]" }.joined(separator: " "))
            lines.append("")
        }

        // Transcript
        if includeTranscript {
            let sorted = meeting.segments.sorted { $0.startTime < $1.startTime }
            if !sorted.isEmpty {
                lines.append("## Transcript")
                lines.append("")
                for segment in sorted {
                    lines.append("> **\(segment.speaker.displayName)** (\(segment.formattedTimestamp)): \(segment.text)")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?\"<>|*")
        return name.unicodeScalars
            .filter { !illegal.contains($0) }
            .map { String($0) }
            .joined()
    }

    private static func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
