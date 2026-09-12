import SwiftData
import SwiftUI

struct MeetingPrepView: View {
    let context: MeetingPrepContext

    @Environment(\.modelContext) private var modelContext
    /// The live tasks behind the prep snapshot, keyed by id, so a status
    /// change during the call lands on the real record. Prep is used *in*
    /// the meeting to remember what to raise, and raising it is when the
    /// item gets resolved — leaving the app to change it later is the gap.
    @State private var liveItems: [UUID: ActionItem] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Meeting Prep", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                if case .history(let count, let mostRecent) = context.provenance {
                    Text(Self.historySummary(count: count, mostRecent: mostRecent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch context.provenance {
            case .firstOccurrence(let title):
                statedMessage(
                    icon: "clock.arrow.circlepath",
                    text: "First time recording “\(title)”. Once you've recorded it before, unresolved items, open questions, and recent topics from past occurrences will appear here."
                )
            case .history:
                if context.hasContent {
                    contentSections
                } else {
                    statedMessage(
                        icon: "checkmark.circle",
                        text: "Nothing carried over from last time — no open items or questions."
                    )
                }
            case .notApplicable:
                EmptyView()
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .task(id: context.unresolvedItems.map(\.id)) { loadLiveItems() }
    }

    /// Resolve the snapshot's ids to live tasks. The snapshot outlives the
    /// meeting-prep fetch, so a task deleted meanwhile simply renders static.
    private func loadLiveItems() {
        let ids = context.unresolvedItems.map(\.id)
        guard !ids.isEmpty else { liveItems = [:]; return }
        let descriptor = FetchDescriptor<ActionItem>(predicate: #Predicate { ids.contains($0.id) })
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        liveItems = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Copy (presentation owns the wording; the service carries only data)

    /// Provenance line for the prep card when prior occurrences exist.
    nonisolated static func historySummary(count: Int, mostRecent: Date?) -> String {
        if count <= 1 {
            if let mostRecent {
                return "From the last time you recorded this meeting · \(shortDate(mostRecent))"
            }
            return "From the last time you recorded this meeting"
        }
        return "From your last \(count) recordings of this meeting"
    }

    nonisolated static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - States

    private func statedMessage(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Content (history with carried-over items)

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !context.unresolvedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Unresolved Items")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        if !liveItems.isEmpty {
                            Text("click to mark done · right-click for more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    ForEach(context.unresolvedItems.prefix(5)) { item in
                        if let live = liveItems[item.id] {
                            PrepActionItemRow(item: item, task: live) { site in
                                PersistenceGate.save(modelContext, site: "MeetingPrep.\(site)", meetingID: live.meeting?.id)
                            }
                        } else {
                            PrepActionItemStaticRow(item: item)
                        }
                    }
                }
            }

            if !context.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Questions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)

                    ForEach(context.followUps.prefix(3), id: \.self) { question in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.top, 2)
                            Text(question)
                                .font(.caption)
                        }
                    }
                }
            }

            if !context.previousTopics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous Topics")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 4) {
                        ForEach(context.previousTopics.prefix(8), id: \.self) { topic in
                            Text(topic)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rows

/// What a prep task reads as. Derived from the live record each time, so
/// the row follows edits made anywhere in the app.
enum PrepTaskStatus: Equatable {
    case pending
    case done
    case wontDo

    init(_ task: ActionItem) {
        if task.isCompleted { self = .done }
        else if task.isDismissed { self = .wontDo }
        else { self = .pending }
    }

    /// The three statuses map onto two stored fields; setting one clears the
    /// other so a task is never both done and dropped.
    func apply(to task: ActionItem) {
        switch self {
        case .pending:
            task.isCompleted = false
            task.dismissedAt = nil
        case .done:
            task.isCompleted = true
            task.dismissedAt = nil
        case .wontDo:
            task.isCompleted = false
            task.dismissedAt = .now
        }
    }
}

/// One carried-over task with its status live. The item stays on the card
/// after it is resolved — struck through, so mid-call you can see what you
/// have covered — and drops out of prep at the next occurrence.
private struct PrepActionItemRow: View {
    let item: PrepActionItem
    @Bindable var task: ActionItem
    let onChange: (String) -> Void

    private var status: PrepTaskStatus { PrepTaskStatus(task) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                set(status == .done ? .pending : .done, site: "toggleDone")
            } label: {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
            .help(status == .done ? "Mark as pending" : "Mark as done")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.caption)
                    .strikethrough(status != .pending, color: .secondary)
                    .foregroundStyle(status == .pending ? .primary : .secondary)
                HStack(spacing: 4) {
                    if let assignee = item.assignee {
                        Text(assignee)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(status == .wontDo ? "won't do" : "\(item.daysSinceCreated)d ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if status != .done {
                Button("Mark as Done") { set(.done, site: "done") }
            }
            if status != .wontDo {
                Button("Won't Do") { set(.wontDo, site: "wontDo") }
            }
            if status != .pending {
                Button("Mark as Pending") { set(.pending, site: "pending") }
            }
        }
    }

    private var icon: String {
        switch status {
        case .pending: "circle"
        case .done: "checkmark.circle.fill"
        case .wontDo: "nosign"
        }
    }

    private var iconColor: Color {
        switch status {
        case .pending: item.daysSinceCreated > 14 ? .red : .orange
        case .done: .green
        case .wontDo: .secondary
        }
    }

    private func set(_ status: PrepTaskStatus, site: String) {
        status.apply(to: task)
        onChange(site)
    }
}

/// The read-only row, for a task the store no longer has.
private struct PrepActionItemStaticRow: View {
    let item: PrepActionItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundStyle(item.daysSinceCreated > 14 ? .red : .orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.caption)
                HStack(spacing: 4) {
                    if let assignee = item.assignee {
                        Text(assignee)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(item.daysSinceCreated)d ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
