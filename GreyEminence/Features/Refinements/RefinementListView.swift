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

    private var backfill = RefinementBackfill.shared
    private var store = RefinementReportStore.shared
    @AppStorage("refinementConfidence") private var confidenceRaw = RefinementConfidence.possibly.rawValue

    // Explicit: a private stored property makes the synthesized memberwise
    // initializer private on CI's older toolchain.
    init(selectedTopic: Binding<RefinementTopic?>, onOpenMeeting: @escaping (Meeting) -> Void) {
        _selectedTopic = selectedTopic
        self.onOpenMeeting = onOpenMeeting
    }

    private var confidence: RefinementConfidence {
        RefinementConfidence(rawValue: confidenceRaw) ?? .possibly
    }

    private var candidates: [Meeting] {
        meetings.filter { $0.status == .completed && $0.isRefinementCandidate }
    }

    /// What the slider lets through. Meetings you added yourself always
    /// show, whatever their score.
    private var visible: [Meeting] {
        candidates.filter { confidence.includes($0) }
    }

    private var sections: [(String, [Meeting])] {
        MeetingListView.groupDateSections(for: visible, now: .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            if backfill.isRunning || backfill.lastError != nil {
                backfillBanner
                Divider()
            }
            confidenceFilter
            Divider()
            List(selection: $selectedTopic) {
                ForEach(sections, id: \.0) { title, sectionMeetings in
                    Section {
                        ForEach(sectionMeetings.flatMap(RefinementTopic.topics(for:))) { topic in
                            RefinementRow(topic: topic, report: store.report(for: topic), isGenerating: store.isGenerating(topic))
                                .tag(topic)
                                .contextMenu {
                                    Button {
                                        onOpenMeeting(topic.meeting)
                                    } label: {
                                        Label("Open Meeting", systemImage: "arrow.up.forward.app")
                                    }
                                    Divider()
                                    MeetingRefinementButton(meeting: topic.meeting)
                                }
                        }
                    } header: {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.inset)
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
        }
    }

    /// Possibly · Likely · Definitely, as a three-stop slider.
    private var confidenceFilter: some View {
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
            Text("\(visible.count) of \(candidates.count) · \(confidence.explanation)")
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

private struct RefinementRow: View {
    let topic: RefinementTopic
    let report: RefinementReport?
    let isGenerating: Bool

    private var meeting: Meeting { topic.meeting }

    var body: some View {
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
        } else if let issue = report?.jiraIssue {
            Label(issue.key, systemImage: "ticket.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
                .help("Jira ticket \(issue.key) created")
        } else if report != nil {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(RefinementStyle.tint)
                .help("Report ready")
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

/// Add to / Remove from Refinements, for meeting context menus. The user's
/// choice overrides the analysis either way.
struct MeetingRefinementButton: View {
    @Bindable var meeting: Meeting

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

    var label: String {
        switch self {
        case .possibly: "possibly"
        case .likely: "likely"
        case .definitely: "definitely"
        }
    }

    var explanation: String {
        switch self {
        case .possibly: "scored 50% or more"
        case .likely: "scored 70% or more"
        case .definitely: "scored 85% or more"
        }
    }

    func includes(_ meeting: Meeting) -> Bool {
        meeting.refinementOverride == true || (meeting.refinementLikelihood ?? 0) >= minimum
    }
}
