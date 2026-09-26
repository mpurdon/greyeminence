import Foundation

/// How the Refinements list is sectioned.
enum RefinementGrouping: String, CaseIterable, Identifiable {
    case date, meeting, status, topic

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// One header on the Refinements list and the rows beneath it.
struct RefinementListSection: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let topics: [RefinementTopic]
    /// Set on Topic sections: the topic's kind, for its icon and menu.
    var topicKind: TopicKind?
    var isTopic = false
}

@MainActor
enum RefinementListGrouper {
    /// Topic sections shown, at most. A library has thousands of topics —
    /// most in a single meeting — and a list of that many sections is slow
    /// to build and useless to scan.
    nonisolated static let topicSectionLimit = 50

    /// `topics` newest meeting first, each meeting's features together.
    static func sections(
        _ topics: [RefinementTopic],
        by grouping: RefinementGrouping,
        topicOrder: TopicMapSort = .mentions,
        resolver: TopicResolver = TopicResolver(),
        status: (RefinementTopic) -> RefinementStatus,
        now: Date = .now
    ) -> [RefinementListSection] {
        switch grouping {
        // Meeting mode has the same date blocks; the list draws each
        // meeting once, with its features under it.
        case .date, .meeting: byDate(topics, now: now)
        case .status: byStatus(topics, status: status)
        case .topic: byMeetingTopic(topics, order: topicOrder, resolver: resolver)
        }
    }

    private static func byDate(_ topics: [RefinementTopic], now: Date) -> [RefinementListSection] {
        let byMeeting = Dictionary(grouping: topics, by: \.meeting.id)
        return MeetingListView.groupDateSections(for: meetings(in: topics), now: now).map { title, meetings in
            RefinementListSection(id: "date:\(title)", title: title, topics: meetings.flatMap { byMeeting[$0.id] ?? [] })
        }
    }

    /// In review order: what needs attention first, settled and rejected last.
    private static func byStatus(_ topics: [RefinementTopic], status: (RefinementTopic) -> RefinementStatus) -> [RefinementListSection] {
        let byStatus = Dictionary(grouping: topics, by: status)
        return RefinementStatus.allCases.compactMap { status in
            guard let topics = byStatus[status] else { return nil }
            return RefinementListSection(id: "status:\(status.rawValue)", title: status.label, topics: topics)
        }
    }

    /// The meetings' own topics, as the Topic Map counts them: one section
    /// per topic, holding every refinement from a meeting that covered it.
    /// A meeting with several topics shows under each. `resolver` merges
    /// aliases and leaves out hidden kinds — People, by default: they say
    /// nothing about which feature a refinement was about.
    private static func byMeetingTopic(_ topics: [RefinementTopic], order: TopicMapSort, resolver: TopicResolver) -> [RefinementListSection] {
        struct Bucket {
            var labels: [String: Int] = [:]
            var kind: TopicKind?
            var meetingIDs: Set<UUID> = []
            var latest = Date.distantPast
            var topics: [RefinementTopic] = []
        }
        let byMeeting = Dictionary(grouping: topics, by: \.meeting.id)
        var buckets: [String: Bucket] = [:]
        var untopical: [RefinementTopic] = []

        for meeting in meetings(in: topics) {
            let rows = byMeeting[meeting.id] ?? []
            var seen = Set<String>()
            let names = (meeting.latestInsight?.topics ?? []).compactMap { raw -> (key: String, label: String, kind: TopicKind?)? in
                guard let resolved = resolver.resolve(raw), seen.insert(resolved.key).inserted else { return nil }
                return (resolved.key, resolved.displayName ?? raw.trimmingCharacters(in: .whitespacesAndNewlines), resolved.kind)
            }
            if names.isEmpty {
                untopical += rows
                continue
            }
            for (key, label, kind) in names {
                var bucket = buckets[key, default: Bucket()]
                bucket.labels[label, default: 0] += 1
                bucket.kind = bucket.kind ?? kind
                bucket.meetingIDs.insert(meeting.id)
                bucket.latest = max(bucket.latest, meeting.date)
                bucket.topics += rows
                buckets[key] = bucket
            }
        }

        let ordered = buckets.sorted { a, b in
            let (x, y) = (a.value, b.value)
            switch order {
            case .mentions:
                if x.meetingIDs.count != y.meetingIDs.count { return x.meetingIDs.count > y.meetingIDs.count }
                if x.latest != y.latest { return x.latest > y.latest }
            case .recent:
                if x.latest != y.latest { return x.latest > y.latest }
                if x.meetingIDs.count != y.meetingIDs.count { return x.meetingIDs.count > y.meetingIDs.count }
            }
            return a.key < b.key
        }
        // Topics that group something — two meetings or more — up to the
        // limit; the rest of the refinements go under Other Topics, so
        // none go missing.
        let shown = ordered.filter { $0.value.meetingIDs.count >= 2 }.prefix(topicSectionLimit)
        let placed = Set(shown.flatMap { $0.value.topics.map(\.id) })
        var sections = shown.map { key, bucket in
            let count = bucket.meetingIDs.count
            return RefinementListSection(
                id: "topic:\(key)",
                title: bucket.labels.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? key,
                subtitle: count == 1 ? "1 meeting" : "\(count) meetings",
                topics: bucket.topics,
                topicKind: bucket.kind,
                isTopic: true
            )
        }
        var seen = Set(untopical.map(\.id))
        let other = topics.filter { !placed.contains($0.id) && seen.insert($0.id).inserted }
        if !other.isEmpty {
            sections.append(RefinementListSection(id: "topic:~other", title: "Other Topics", subtitle: "topics from one meeting", topics: other))
        }
        if !untopical.isEmpty {
            sections.append(RefinementListSection(id: "topic:", title: "No Topics", topics: untopical))
        }
        return sections
    }

    /// The Topic Map's key: case and surrounding space don't make a new topic.
    nonisolated static func normalize(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A block's topics as consecutive runs, one per meeting — for Meeting
    /// mode, which heads each run with its meeting.
    static func meetingRuns(_ topics: [RefinementTopic]) -> [(meeting: Meeting, topics: [RefinementTopic])] {
        var runs: [(meeting: Meeting, topics: [RefinementTopic])] = []
        for topic in topics {
            if let last = runs.indices.last, runs[last].meeting.id == topic.meeting.id {
                runs[last].topics.append(topic)
            } else {
                runs.append((topic.meeting, [topic]))
            }
        }
        return runs
    }

    /// Distinct meetings, in the order their topics arrive.
    private static func meetings(in topics: [RefinementTopic]) -> [Meeting] {
        var seen = Set<UUID>()
        return topics.map(\.meeting).filter { seen.insert($0.id).inserted }
    }
}
