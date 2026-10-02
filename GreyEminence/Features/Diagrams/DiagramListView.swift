import SwiftData
import SwiftUI

/// Meetings with something to draw — a flow or a timeline, detected by the
/// final analysis or, for older meetings, the backfill.
struct DiagramListView: View {
    @Binding var selectedTopic: DiagramTopic?
    var onOpenMeeting: (Meeting) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @AppStorage("diagramKindFilter") private var kindFilter = ""

    private var index: DiagramIndexStore { .shared }
    private var store: DiagramStore { .shared }
    private var backfill: DiagramBackfill { .shared }

    private static func topics(in meetings: [Meeting], index: DiagramIndexStore, kind: DiagramKind?) -> [DiagramTopic] {
        var topics: [DiagramTopic] = []
        for meeting in meetings where meeting.status == .completed && !meeting.isInterviewMeeting {
            for signal in index.signals(for: meeting.id) where kind == nil || signal.kind == kind {
                topics.append(DiagramTopic(meeting: meeting, signal: signal))
            }
        }
        return topics
    }

    var body: some View {
        let kind = DiagramKind(rawValue: kindFilter)
        let topics = Self.topics(in: meetings, index: index, kind: kind)
        let byMeeting = Dictionary(grouping: topics, by: \.meeting.id)
        let sections = MeetingListView.groupDateSections(for: meetings.filter { byMeeting[$0.id] != nil }, now: .now)
        VStack(spacing: 0) {
            if backfill.isRunning || backfill.lastError != nil {
                BackfillBanner(isRunning: backfill.isRunning, checked: backfill.checked, total: backfill.total,
                               lastError: backfill.lastError, activity: "Looking through older meetings")
                Divider()
            }
            Picker("Kind", selection: $kindFilter) {
                Text("All").tag("")
                ForEach(DiagramKind.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $selectedTopic) {
                ForEach(sections, id: \.0) { title, sectionMeetings in
                    Section {
                        ForEach(sectionMeetings.flatMap { byMeeting[$0.id] ?? [] }) { topic in
                            DiagramRow(topic: topic, isBuilt: store.diagram(for: topic) != nil, isGenerating: store.isGenerating(topic))
                                .tag(topic)
                                .contextMenu {
                                    Button {
                                        onOpenMeeting(topic.meeting)
                                    } label: {
                                        Label("Open Meeting", systemImage: "arrow.up.forward.app")
                                    }
                                    Button {
                                        DiagramDetailView.copy(topic.diagramID)
                                    } label: {
                                        Label("Copy ID", systemImage: "number")
                                    }
                                    Button("Detect and Redraw This Meeting's Diagrams") {
                                        store.detectAgain(topic.meeting)
                                    }
                                    .disabled(store.redetecting.contains(topic.meeting.id))
                                    Divider()
                                    Button("Not a \(topic.signal.kind.label)") {
                                        index.dismiss(topic.signal, for: topic.meeting.id)
                                    }
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
            .listStyle(.sidebar)
            .overlay {
                if topics.isEmpty && !backfill.isRunning {
                    ContentUnavailableView {
                        Label("Nothing to Draw Yet", systemImage: DiagramStyle.symbol)
                    } description: {
                        Text("Meetings that walk through a sequence of steps, or set out deliverables with dates, show up here after they're analyzed.")
                    }
                }
            }
        }
        .navigationTitle("Diagrams")
        .onAppear {
            FeatureDiscovery.shared.markSeen("diagrams")
            backfill.runIfNeeded(in: modelContext)
        }
    }
}

private struct DiagramRow: View {
    let topic: DiagramTopic
    let isBuilt: Bool
    let isGenerating: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: topic.signal.kind.systemImage)
                .foregroundStyle(DiagramStyle.tint(topic.signal.kind))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.signal.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(topic.meeting.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(topic.meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(topic.meeting.formattedDuration)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if isGenerating {
                ProgressView().controlSize(.small)
            } else if isBuilt {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Drawn")
            }
        }
        .padding(.vertical, 3)
    }
}

enum DiagramStyle {
    static let symbol = "flowchart"
    /// Slate: distinct from every other sidebar colour.
    static let sidebarColor = Color(red: 0.30, green: 0.40, blue: 0.55)

    static func tint(_ kind: DiagramKind) -> Color {
        switch kind {
        case .flow: .teal
        case .timeline: .purple
        }
    }
}
