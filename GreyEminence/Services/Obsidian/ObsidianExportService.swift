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

        let vaultURL = URL(fileURLWithPath: vaultPath)
        let folderURL = vaultURL.appendingPathComponent(subfolder)

        let insight = meeting.latestInsight
        let markdown = buildMarkdown(
            meeting: meeting,
            insight: insight,
            includeTranscript: includeTranscript,
            includeActionItems: includeActionItems,
            includeWikilinks: includeWikilinks
        )

        let dateString = formatDate(meeting.date)
        let baseName = sanitizeFilename("\(meeting.title) — \(dateString)")
        let fileURL = uniqueURL(in: folderURL, baseName: baseName, suffix: meeting.id)

        // All file work happens inside the security-scoped access block so
        // start/stop pair correctly — no retain leak on repeat exports.
        let result: Result<Void, ExportError>? = ObsidianSettingsView.withVaultAccess {
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            } catch {
                return .failure(.vaultAccessDenied)
            }
            do {
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return .failure(.writeFailure(error))
            }
            return .success(())
        }
        switch result {
        case .none: throw ExportError.vaultAccessDenied
        case .some(.failure(let err)): throw err
        case .some(.success): break
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
        let attendeeNames = meeting.presentAttendees.sorted { $0.name < $1.name }.map(\.name)
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

        // Shared Content — observation text + timestamps only (images stay
        // in the app container; copying them into the vault is a bloat and
        // sync-conflict magnet, revisit as an opt-in later). Sessions with a
        // synthesized narrative lead with the recap paragraph.
        let sharedContentLines = sharedContentSection(
            frames: meeting.screenFrames,
            summaries: meeting.sessionSummaries
        )
        if !sharedContentLines.isEmpty {
            lines.append(contentsOf: sharedContentLines)
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

    /// "## Shared Content" — one subsection per share session. Sessions with
    /// a synthesized narrative export the recap paragraph + key moments;
    /// sessions without fall back to one line per frame that has something
    /// to say (observation, or OCR first line). Empty array when the meeting
    /// captured nothing.
    @MainActor
    private static func sharedContentSection(
        frames: [ScreenShareFrame],
        summaries: [ShareSessionSummary]
    ) -> [String] {
        guard !frames.isEmpty else { return [] }
        let sessions = ShareSession.sessions(from: frames)
        let bySession = Dictionary(grouping: frames, by: \.sessionID)
        let summariesBySession = Dictionary(uniqueKeysWithValues: summaries.map { ($0.sessionID, $0) })

        var lines: [String] = ["## Shared Content", ""]
        var wroteAnySession = false
        for (index, session) in sessions.enumerated() {
            let start = formatTimestamp(session.startTime)
            let end = formatTimestamp(session.endTime)
            lines.append("### Share session \(index + 1) (\(start)–\(end))")
            lines.append("")

            if let summary = summariesBySession[session.id] {
                lines.append(summary.narrative)
                let moments = summary.keyMoments
                if !moments.isEmpty {
                    lines.append("")
                    for moment in moments {
                        lines.append("- **[\(formatTimestamp(moment.timestamp))]** \(moment.label)")
                    }
                }
                lines.append("")
                wroteAnySession = true
                continue
            }

            let sessionFrames = (bySession[session.id] ?? []).sorted { $0.timestamp < $1.timestamp }
            var entryLines: [String] = []
            var seen = Set<String>()
            for frame in sessionFrames {
                if let observation = frame.observation, !observation.isEmpty {
                    guard seen.insert(observation).inserted else { continue }
                    entryLines.append("- **[\(frame.formattedTimestamp)]** \(observation)")
                } else if let firstLine = frame.ocrText?.components(separatedBy: "\n").first,
                          !firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard seen.insert(firstLine).inserted else { continue }
                    entryLines.append("- **[\(frame.formattedTimestamp)]** (on screen) \(firstLine)")
                }
            }
            if entryLines.isEmpty {
                lines.append("_\(session.frameCount) frame(s) captured — no readable content._")
            } else {
                lines.append(contentsOf: entryLines)
            }
            lines.append("")
            wroteAnySession = true
        }
        return wroteAnySession ? lines : []
    }

    private static func formatTimestamp(_ time: TimeInterval) -> String {
        String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }

    // MARK: - Helpers

    /// Returns a URL that doesn't collide with existing files. If `baseName.md` exists,
    /// appends a short UUID prefix: `baseName — abc123.md`.
    private static func uniqueURL(in folder: URL, baseName: String, suffix: UUID) -> URL {
        let candidate = folder.appendingPathComponent("\(baseName).md")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let shortID = String(suffix.uuidString.prefix(6).lowercased())
        return folder.appendingPathComponent("\(baseName) — \(shortID).md")
    }

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
