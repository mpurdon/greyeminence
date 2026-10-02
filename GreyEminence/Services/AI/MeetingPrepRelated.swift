import Foundation

/// Background for a meeting with no recorded history of its own: what other
/// meetings have said about its subject, distilled into a few points.
///
/// Kept apart from the series prep on purpose. Series prep is what *this*
/// meeting left open; this is what the rest of the user's meetings say about
/// the subject its title names. The card labels them differently so one is
/// never mistaken for the other. Matching is on the title's distinctive
/// words — never on attendees, who sit in many unrelated meetings.
///
/// Codable for the scheduler's on-disk cache. It's regenerable, so a file
/// that no longer decodes is simply dropped and rebuilt.
struct RelatedPrep: Codable, Sendable, Equatable {
    struct Source: Codable, Sendable, Equatable {
        let meetingID: UUID
        let title: String
        let date: Date
        /// The best-ranked excerpt, for when there are no points to show.
        let excerpt: String
    }

    struct Point: Codable, Sendable, Equatable {
        let text: String
        /// Indices into `sources`.
        let sourceIndices: [Int]
    }

    let keywords: [String]
    let points: [Point]
    let sources: [Source]
    /// The summary call failed or no AI is configured, so the card lists
    /// the matching meetings instead of points.
    let summaryUnavailable: Bool
    let generatedAt: Date
}

enum RelatedPrepStatus: Sendable, Equatable {
    case notRequested
    case loading
    case ready(RelatedPrep)
    /// Searched; nothing substantive about the subject anywhere.
    case none

    var prep: RelatedPrep? {
        if case .ready(let prep) = self { return prep }
        return nil
    }
}

enum MeetingPrepRelated {
    /// Search only this far back — older discussion is more likely stale
    /// than useful a few minutes before the call.
    static let lookbackDays = 90
    static let maxMeetings = 6
    static let perMeetingCap = 3
    static let maxPoints = 5

    /// Words that name the *kind* of meeting rather than its subject. "Cadence
    /// Eng Sync" is about Cadence; searching "eng sync" would match every sync.
    static let genericTitleWords: Set<String> = [
        "sync", "eng", "engineering", "weekly", "daily", "monthly", "quarterly",
        "biweekly", "bi", "standup", "stand", "up", "meeting", "mtg", "review",
        "check", "checkin", "in", "catch", "catchup", "touch", "base", "touchbase",
        "team", "call", "chat", "update", "updates", "status", "planning", "plan",
        "discussion", "discuss", "session", "huddle", "1", "1on1", "one", "on",
        "the", "and", "with", "for", "of", "to", "a", "an", "re", "fw", "fwd",
        "new", "recurring", "series", "internal", "office", "hours", "time",
        "kickoff", "kick", "off", "retro", "retrospective", "demo", "follow",
        "progress", "prep", "prepare", "preparation", "pre",
    ]

    // MARK: - Pure helpers (unit-tested without the store or a model)

    /// The title's distinctive words, lowercased, in title order. Empty when
    /// the title is all meeting-kind words ("Weekly Sync") — nothing to search.
    nonisolated static func keywords(fromTitle title: String) -> [String] {
        var seen = Set<String>()
        return title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !genericTitleWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            .filter { seen.insert($0).inserted }
    }

    /// Results that actually name a keyword, grouped by meeting. The dense
    /// pass happily returns near-misses; a background point built on a
    /// snippet that never mentions the subject is invented context.
    ///
    /// Meetings held earlier on `meetingStart`'s day take the first slots
    /// whatever their rank — a meeting to prepare for this one is the most
    /// useful context there is, and one passing mention can rank it low.
    nonisolated static func select(
        results: [SearchResult],
        keywords: [String],
        excludingMeetingIDs excluded: Set<UUID> = [],
        meetingStart: Date? = nil
    ) -> [(source: RelatedPrep.Source, excerpts: [String])] {
        guard let regex = keywordRegex(keywords) else { return [] }
        var order: [UUID] = []
        var groups: [UUID: (source: RelatedPrep.Source, excerpts: [String])] = [:]
        for result in results where !excluded.contains(result.meetingID) {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, matches(text, regex) else { continue }
            if var group = groups[result.meetingID] {
                guard group.excerpts.count < perMeetingCap else { continue }
                group.excerpts.append(text)
                groups[result.meetingID] = group
            } else {
                order.append(result.meetingID)
                let source = RelatedPrep.Source(
                    meetingID: result.meetingID,
                    title: result.meetingTitle,
                    date: result.meetingDate,
                    excerpt: String(text.prefix(220))
                )
                groups[result.meetingID] = (source, [text])
            }
        }
        let ranked = order.compactMap { groups[$0] }
        let sameDay = ranked.filter { isEarlierSameDay($0.source.date, meetingStart) }
        let rest = ranked.filter { !isEarlierSameDay($0.source.date, meetingStart) }
        // Newest first: the latest state of a subject is what matters going in.
        return Array((sameDay + rest).prefix(maxMeetings)).sorted { $0.source.date > $1.source.date }
    }

    nonisolated static func isEarlierSameDay(_ date: Date, _ meetingStart: Date?) -> Bool {
        guard let meetingStart else { return false }
        return date < meetingStart && Calendar.current.isDate(date, inSameDayAs: meetingStart)
    }

    nonisolated static let systemPrompt = """
        You brief someone a few minutes before a meeting. You get the meeting's \
        title and excerpts from transcripts of their OTHER, earlier meetings \
        that mention its subject. There is no agenda.

        Meetings marked "earlier today" may have been held to prepare for \
        this one — lead with what they concluded or planned to raise.

        Write up to \(maxPoints) short background points they'd want in mind \
        walking in: where things stand, open decisions or problems, commitments \
        made, who is involved. Use only what the excerpts say — never guess at \
        the upcoming meeting's agenda. Prefer the newest state when excerpts \
        conflict. Each point is one sentence and cites the meetings it draws on.

        If the excerpts only mention the subject in passing and say nothing \
        substantive, return an empty list.

        Respond with JSON only: {"points":[{"text":"…","meetings":["M1","M2"]}]}
        """

    nonisolated static func prompt(
        title: String,
        keywords: [String],
        groups: [(source: RelatedPrep.Source, excerpts: [String])],
        meetingStart: Date? = nil
    ) -> String {
        var lines = [
            "Upcoming meeting: “\(title)”",
            "Subject keywords: \(keywords.joined(separator: ", "))",
            "",
            "Excerpts (newest meeting first):",
        ]
        for (index, group) in groups.enumerated() {
            let date = group.source.date.formatted(date: .abbreviated, time: .omitted)
            lines.append("")
            let today = isEarlierSameDay(group.source.date, meetingStart) ? " (earlier today)" : ""
            lines.append("[M\(index + 1)] \(group.source.title) — \(date)\(today)")
            for excerpt in group.excerpts {
                lines.append("- \(excerpt.prefix(600))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `{"points":[{"text":…,"meetings":["M2"]}]}` → points with source
    /// indices. Unknown meeting ids are dropped; a point with no text is.
    nonisolated static func parse(response: String, sourceCount: Int) -> [RelatedPrep.Point]? {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let items = object["points"] as? [[String: Any]] else { return nil }
        return items.prefix(maxPoints).compactMap { item in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let ids = item["meetings"] as? [String] ?? []
            let indices = ids.compactMap { id -> Int? in
                guard id.hasPrefix("M"), let n = Int(id.dropFirst()), (1...sourceCount).contains(n) else { return nil }
                return n - 1
            }
            return RelatedPrep.Point(text: text, sourceIndices: Array(Set(indices)).sorted())
        }
    }

    nonisolated private static func keywordRegex(_ keywords: [String]) -> NSRegularExpression? {
        let alternatives = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard !alternatives.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: "\\b(?:\(alternatives))\\b", options: [.caseInsensitive])
    }

    nonisolated private static func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Build

    /// Search transcripts for the title's subject and distil the matches.
    /// nil when there's nothing to search for or nothing substantive found.
    @MainActor
    static func build(
        title: String,
        meetingStart: Date,
        excludingMeetingIDs excluded: Set<UUID> = []
    ) async -> RelatedPrep? {
        let keywords = keywords(fromTitle: title)
        guard !keywords.isEmpty, let store = EmbeddingStore.shared else { return nil }

        let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider") ?? EmbeddingProvider.nlEmbedding.rawValue
        let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
        let service = provider.makeService()
        guard service.isAvailable else { return nil }

        let now = Date.now
        let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        let search = SemanticSearchService(store: store, service: service)
        let results = await search.search(
            keywords.joined(separator: " "),
            // Generous: a busy subject has hundreds of passages, and today's
            // prep meeting must survive the cut to be promoted.
            topK: 200,
            dateRange: since...now,
            kinds: [.transcriptSegment]
        )
        let groups = select(results: results, keywords: keywords, excludingMeetingIDs: excluded, meetingStart: meetingStart)
        LogManager.send(
            "Prep: related search for “\(title)” [\(keywords.joined(separator: ", "))] — \(results.count) hit(s), \(groups.count) meeting(s) name it",
            category: .general
        )
        guard !groups.isEmpty else { return nil }
        let sources = groups.map(\.source)

        do {
            guard let client = try await AIClientFactory.makeLightClient() else {
                return RelatedPrep(keywords: keywords, points: [], sources: sources, summaryUnavailable: true, generatedAt: .now)
            }
            let response = try await AILongRequest.send(
                client,
                system: systemPrompt,
                prompt: prompt(title: title, keywords: keywords, groups: groups, meetingStart: meetingStart),
                maxTokens: 800,
                timeoutSeconds: 60,
                purpose: .prep,
                label: "Meeting prep (related)"
            )
            guard let points = parse(response: response, sourceCount: sources.count) else {
                LogManager.send("Prep: unreadable related-context response", category: .general, level: .warning)
                return RelatedPrep(keywords: keywords, points: [], sources: sources, summaryUnavailable: true, generatedAt: .now)
            }
            // The model judged every mention to be in passing.
            guard !points.isEmpty else { return nil }
            return RelatedPrep(keywords: keywords, points: points, sources: sources, summaryUnavailable: false, generatedAt: .now)
        } catch {
            LogManager.send("Prep: related-context summary failed — \(error.localizedDescription)", category: .general, level: .warning)
            return RelatedPrep(keywords: keywords, points: [], sources: sources, summaryUnavailable: true, generatedAt: .now)
        }
    }
}
