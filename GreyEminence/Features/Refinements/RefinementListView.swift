import SwiftData
import SwiftUI

/// Features refined in meetings — flagged by the final analysis, by the
/// backfill for older meetings, or added by hand. A meeting that refined
/// several features has a row for each.
struct RefinementListView: View {
    @Binding var selectedTopic: RefinementTopic?
    var onOpenMeeting: (Meeting) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query private var contacts: [Contact]

    private var backfill: RefinementBackfill { .shared }
    private var store: RefinementReportStore { .shared }
    @AppStorage("refinementConfidence") private var confidenceRaw = RefinementConfidence.possibly.rawValue
    @AppStorage("refinementGrouping") private var grouping: RefinementGrouping = .date
    @AppStorage("refinementTopicOrder") private var topicOrder: TopicMapSort = .mentions
    @AppStorage("refinementShowRejected") private var showRejected = false
    /// Topic kinds left out of the Topic grouping. People by default.
    @AppStorage("refinementHiddenTopicKinds") private var hiddenTopicKinds = TopicKind.person.rawValue
    /// Folded sections, by section ID. Topic sections start folded — there
    /// are many, and the headers are the point.
    @State private var folded: Set<String> = []
    /// A reference, so filling it from the body isn't a state change.
    @State private var sectionCache = SectionCache()
    @State private var unfoldedTopics: Set<String> = []

    private var confidence: RefinementConfidence {
        RefinementConfidence(rawValue: confidenceRaw) ?? .possibly
    }

    var body: some View {
        let candidates = meetings.filter { $0.status == .completed && $0.isRefinementCandidate }
        // What the slider lets through. Meetings you added yourself always
        // show, whatever their score.
        let visible = candidates.filter { confidence.includes($0) }
        // Rejected rows stay out of the way unless asked for.
        let rows = visible.flatMap(RefinementTopic.topics(for:))
            .filter { showRejected || store.status(for: $0) != .rejected }
        let sections = sections(for: rows)
        VStack(spacing: 0) {
            if backfill.isRunning || backfill.lastError != nil {
                backfillBanner
                Divider()
            }
            confidenceFilter(showing: visible.count, of: candidates.count)
            Divider()
            groupingBar
                .zIndex(1)  // the kind legend drops over the list
            List(selection: $selectedTopic) {
                ForEach(sections) { section in
                    Section(isExpanded: expansion(for: section.id)) {
                        if grouping == .meeting {
                            ForEach(RefinementListGrouper.meetingRuns(section.topics), id: \.meeting.id) { run in
                                RefinementMeetingHeader(meeting: run.meeting, onOpenMeeting: onOpenMeeting)
                                ForEach(run.topics) { topic in
                                    row(topic)
                                }
                            }
                        } else {
                            ForEach(section.topics) { topic in
                                row(topic)
                            }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if visible.isEmpty && !candidates.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing \(confidence.label)", systemImage: "slider.horizontal.3")
                    } description: {
                        Text("Slide toward Possibly to see the \(candidates.count) meetings that might be refinements.")
                    }
                } else if candidates.isEmpty && !backfill.isRunning {
                    ContentUnavailableView {
                        Label("No Refinements Yet", systemImage: RefinementStyle.symbol)
                    } description: {
                        Text("Meetings where you work through a feature show up here after they're analyzed. To add one yourself, right-click it in Meetings and choose Add to Refinements.")
                    }
                }
            }
        }
        .navigationTitle("Refinements")
        .onAppear {
            FeatureDiscovery.shared.markSeen("refinement-report")
            backfill.runIfNeeded(in: modelContext)
            TopicClassifier.shared.runIfNeeded(in: modelContext)
        }
    }

    /// The grouped sections, rebuilt only when something they depend on
    /// changes. The body runs on every selection and hover; grouping by
    /// Topic reads every meeting's topics and took over 100 ms, so
    /// rebuilding it each time made every click lag.
    private func sections(for rows: [RefinementTopic]) -> [RefinementListSection] {
        var hasher = Hasher()
        hasher.combine(grouping)
        hasher.combine(topicOrder)
        hasher.combine(hiddenTopicKinds)
        hasher.combine(store.revision)             // statuses
        hasher.combine(TopicCatalogStore.shared.revision)
        hasher.combine(contacts.count)
        hasher.combine(Calendar.current.startOfDay(for: .now)) // date blocks
        for row in rows { hasher.combine(row.id) }
        let key = hasher.finalize()
        if sectionCache.key == key { return sectionCache.sections }

        let started = Date.now
        let sections = RefinementListGrouper.sections(
            rows,
            by: grouping,
            topicOrder: topicOrder,
            resolver: grouping == .topic
                ? TopicCatalogStore.shared.resolver(hiding: TopicKind.set(from: hiddenTopicKinds), contactNames: contacts.map(\.name))
                : TopicResolver(),
            status: store.status(for:)
        )
        Self.logIfSlow(since: started, grouping: grouping, rows: rows.count, sections: sections.count)
        sectionCache.key = key
        sectionCache.sections = sections
        return sections
    }

    /// If building the list ever gets slow, say so with numbers rather than
    /// leave it to be felt.
    private static func logIfSlow(since started: Date, grouping: RefinementGrouping, rows: Int, sections: Int) {
        let elapsed = Date.now.timeIntervalSince(started)
        guard elapsed > 0.1 else { return }
        LogManager.send("Refinements list: grouping \(rows) rows by \(grouping.rawValue) into \(sections) sections took \(Int(elapsed * 1000)) ms", category: .general, level: .warning)
    }

    private func row(_ topic: RefinementTopic) -> some View {
        let report = store.report(for: topic)
        return RefinementRow(
            topic: topic,
            status: report?.status ?? .notBuilt,
            jiraKey: report?.jiraIssue?.key,
            isGenerating: store.isGenerating(topic),
            isUnderMeeting: grouping == .meeting
        )
        .tag(topic)
        .contextMenu {
            Button {
                onOpenMeeting(topic.meeting)
            } label: {
                Label("Open Meeting", systemImage: "arrow.up.forward.app")
            }
            if report != nil {
                RefinementStatusMenu(topic: topic)
            }
            Divider()
            MeetingRefinementButton(meeting: topic.meeting)
        }
    }

    private func sectionHeader(_ section: RefinementListSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let kind = section.topicKind {
                Image(systemName: kind.systemImage)
                    .font(.caption2)
                    .foregroundStyle(kind.tint)
                    .help(kind.singular)
            }
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(section.topics.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .textCase(nil)
        .contextMenu {
            if section.isTopic {
                TopicCatalogMenuItems(topic: section.title)
            }
        }
    }

    /// Topic sections open on request; every other grouping starts open.
    private func expansion(for id: String) -> Binding<Bool> {
        let isTopic = grouping == .topic
        return Binding(
            get: { isTopic ? unfoldedTopics.contains(id) : !folded.contains(id) },
            set: { open in
                if isTopic {
                    if open { unfoldedTopics.insert(id) } else { unfoldedTopics.remove(id) }
                } else {
                    if open { folded.remove(id) } else { folded.insert(id) }
                }
            }
        )
    }

    /// Grouping, and under it the topic kinds when grouping by Topic; the
    /// filter menu beside both, as tall as they are.
    private var groupingBar: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Group", selection: $grouping) {
                    ForEach(RefinementGrouping.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .newFeatureBadge("refinement-review")
                .onChange(of: grouping) { FeatureDiscovery.shared.markSeen("refinement-review") }
                if grouping == .topic {
                    TopicKindFilterBar(hiddenRaw: $hiddenTopicKinds)
                }
            }
            filterMenu
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var filterMenu: some View {
        Menu {
            if grouping == .topic {
                Picker("Order Topics By", selection: $topicOrder) {
                    ForEach(TopicMapSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Toggle("Show Rejected", isOn: $showRejected)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: grouping == .topic ? 22 : 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(grouping == .topic ? "Topic order and rejected refinements" : "Rejected refinements")
    }

    /// Possibly · Likely · Definitely, as a three-stop slider.
    private func confidenceFilter(showing visibleCount: Int, of candidateCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(
                value: Binding(
                    get: { Double(confidenceRaw) },
                    set: { confidenceRaw = Int($0.rounded()) }
                ),
                in: 0...Double(RefinementConfidence.allCases.count - 1),
                step: 1
            )
            .controlSize(.small)
            HStack {
                ForEach(RefinementConfidence.allCases) { level in
                    Button(level.label.capitalized) { confidenceRaw = level.rawValue }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(level == confidence ? .semibold : .regular))
                        .foregroundStyle(level == confidence ? Color.primary : Color.secondary)
                    if level != RefinementConfidence.allCases.last { Spacer() }
                }
            }
            Text("\(visibleCount) of \(candidateCount) · \(confidence.explanation)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("How sure the analysis must be that a meeting was a refinement")
    }

    @ViewBuilder
    private var backfillBanner: some View {
        HStack(spacing: 8) {
            if backfill.isRunning {
                ProgressView().controlSize(.small)
                Text("Checking older meetings… \(backfill.checked) of \(backfill.total)")
            } else if let error = backfill.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't check older meetings: \(error)")
                    .lineLimit(2)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private final class SectionCache {
    var key: Int?
    var sections: [RefinementListSection] = []
}

private struct RefinementRow: View {
    let topic: RefinementTopic
    let status: RefinementStatus
    let jiraKey: String?
    let isGenerating: Bool
    /// In Meeting mode the meeting's header carries its title, time,
    /// speakers and likelihood; the row is just the feature, indented.
    let isUnderMeeting: Bool

    private var meeting: Meeting { topic.meeting }

    var body: some View {
        if isUnderMeeting {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: RefinementStyle.symbol)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(topic.feature)
                    .lineLimit(2)
                Spacer(minLength: 4)
                statusIcon
            }
            .padding(.leading, 14)
            .padding(.vertical, 2)
        } else {
            fullRow
        }
    }

    private var fullRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(topic.feature)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                statusIcon
            }
            HStack(spacing: 4) {
                Text(meeting.title)
                    .lineLimit(1)
                if topic.count > 1 {
                    Text("· \(topic.position + 1) of \(topic.count)")
                        .fixedSize()
                        .help("One of \(topic.count) features refined in this meeting")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(meeting.formattedDuration)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                RefinementSpeakerDots(voices: RefinementSpeakers.voices(for: meeting))
                Spacer(minLength: 4)
                if meeting.refinementOverride == true {
                    Text("Added by you")
                } else if let likelihood = meeting.refinementLikelihood {
                    Text("\(Int((likelihood * 100).rounded()))% likely")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isGenerating {
            ProgressView().controlSize(.small)
        } else {
            switch status {
            case .notBuilt:
                EmptyView()
            case .new:
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .help("New — not opened yet")
            case .filed:
                Label(jiraKey ?? status.label, systemImage: status.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(status.tint)
                    .help(jiraKey.map { "Jira ticket \($0) created" } ?? status.label)
            default:
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.tint)
                    .help(status.label)
            }
        }
    }
}

/// Meeting mode's heading for one meeting: what the full rows repeat per
/// feature, said once. Not selectable — its features are.
private struct RefinementMeetingHeader: View {
    let meeting: Meeting
    var onOpenMeeting: (Meeting) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.2.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(meeting.formattedDuration)
                RefinementSpeakerDots(voices: RefinementSpeakers.voices(for: meeting))
                Spacer(minLength: 4)
                if meeting.refinementOverride == true {
                    Text("Added by you")
                } else if let likelihood = meeting.refinementLikelihood {
                    Text("\(Int((likelihood * 100).rounded()))% likely")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .selectionDisabled()
        .contextMenu {
            Button {
                onOpenMeeting(meeting)
            } label: {
                Label("Open Meeting", systemImage: "arrow.up.forward.app")
            }
            Divider()
            MeetingRefinementButton(meeting: meeting)
        }
    }
}

/// Initials for the people who actually talked, biggest share first.
private struct RefinementSpeakerDots: View {
    let voices: [RefinementSpeakers.Voice]

    var body: some View {
        let shown = voices.prefix(RefinementSpeakers.maxShown)
        HStack(spacing: -3) {
            ForEach(shown) { voice in
                Text(voice.initials)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(voice.color.gradient, in: Circle())
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                    .help("\(voice.name) — \(Int((voice.share * 100).rounded()))% of the talking")
            }
            if voices.count > shown.count {
                Text("+\(voices.count - shown.count)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())
                    .help(voices.dropFirst(shown.count).map(\.name).joined(separator: ", "))
            }
        }
    }
}

/// Who spoke in a meeting, by share of the words — not the invite list,
/// where half the names may never have said anything. Only people: an
/// unnamed voice ("Speaker 2") says nothing about who took part.
@MainActor
enum RefinementSpeakers {
    struct Voice: Identifiable {
        let name: String
        let initials: String
        let color: Color
        let share: Double
        var id: String { name }
    }

    /// Below this share of the words, someone was present, not contributing.
    nonisolated static let minimumShare = 0.05
    static let maxShown = 5

    /// Keyed by meeting and segment count: tallying walks every segment,
    /// and a list row is drawn far more often than a transcript changes.
    private static var cache: [String: [Voice]] = [:]

    static func voices(for meeting: Meeting) -> [Voice] {
        let key = "\(meeting.id)-\(meeting.segments.count)"
        if let cached = cache[key] { return cached }

        var words: [Speaker: Int] = [:]
        for segment in meeting.segments {
            words[segment.speaker, default: 0] += segment.text.split(whereSeparator: \.isWhitespace).count
        }
        let myID = Meeting.storedMyContactID
        let attendees = meeting.attendees
        let voices = attributedTalkers(words.map { ($0.key, $0.value) }).map { speaker, share in
            let contact: Contact? = speaker.isMe
                ? attendees.first { $0.id == myID }
                : attendees.first { $0.name.caseInsensitiveCompare(speaker.displayName) == .orderedSame }
            return Voice(
                name: contact?.name ?? (speaker.isMe ? "You" : speaker.displayName),
                initials: contact?.initials ?? speaker.initials,
                color: contact?.avatarColor ?? speaker.color,
                share: share
            )
        }
        cache[key] = voices
        return voices
    }

    /// Named speakers at or above `minimumShare`, largest share first.
    /// Unnamed voices still count toward the total, so a person's share is
    /// of everything said, not just of what named people said.
    nonisolated static func attributedTalkers(_ wordCounts: [(Speaker, Int)]) -> [(Speaker, Double)] {
        talkers(wordCounts).filter { !$0.0.isUnidentified }
    }

    /// Speakers at or above `minimumShare`, largest share first.
    nonisolated static func talkers<Key>(_ wordCounts: [(Key, Int)]) -> [(Key, Double)] {
        let total = wordCounts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return wordCounts
            .map { ($0.0, Double($0.1) / Double(total)) }
            .filter { $0.1 >= minimumShare }
            .sorted { $0.1 > $1.1 }
    }
}

/// Set a report's review status, for the report header and list rows.
struct RefinementStatusMenu: View {
    let topic: RefinementTopic
    private var store: RefinementReportStore { .shared }

    var body: some View {
        let current = store.status(for: topic)
        Menu {
            ForEach(RefinementStatus.settable) { status in
                Button {
                    store.setStatus(status, for: topic)
                } label: {
                    if status == current {
                        Label(status.label, systemImage: "checkmark")
                    } else {
                        Text(status.label)
                    }
                }
            }
        } label: {
            Label("Status: \(current.label)", systemImage: current.systemImage)
        }
    }
}

extension RefinementStatus {
    var tint: Color {
        switch self {
        case .notBuilt, .inProgress: .secondary
        case .new: .accentColor
        case .followUp: .orange
        case .accepted: .teal
        case .verified: .green
        case .filed: .blue
        case .rejected: .red
        }
    }
}

/// Add to / Remove from Refinements, for meeting context menus. The user's
/// choice overrides the analysis either way.
struct MeetingRefinementButton: View {
    let meeting: Meeting

    var body: some View {
        Button {
            meeting.refinementOverride = !meeting.isRefinementCandidate
        } label: {
            if meeting.isRefinementCandidate {
                Label("Remove from Refinements", systemImage: "minus.circle")
            } else {
                Label("Add to Refinements", systemImage: RefinementStyle.symbol)
            }
        }
    }
}

/// The list's filter: how sure the analysis must be. Stops sit where the
/// model's scores actually cluster — it answers in round tenths.
enum RefinementConfidence: Int, CaseIterable, Identifiable {
    case possibly
    case likely
    case definitely

    var id: Int { rawValue }

    var minimum: Double {
        switch self {
        case .possibly: 0.5
        case .likely: 0.7
        case .definitely: 0.85
        }
    }

    var label: String { String(describing: self) }

    var explanation: String { "scored \(Int((minimum * 100).rounded()))% or more" }

    func includes(_ meeting: Meeting) -> Bool {
        meeting.refinementOverride == true || (meeting.refinementLikelihood ?? 0) >= minimum
    }
}
