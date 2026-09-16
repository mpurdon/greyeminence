import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Bindable var task: ActionItem
    @Environment(\.dismiss) private var dismiss

    private var meeting: Meeting? { task.meeting }

    /// 3 segments on each side ≈ 60–90 seconds of conversation — enough to
    /// understand intent without dumping the whole meeting.
    private static let contextWindow = 3

    private var contextSegments: [TranscriptSegment] {
        guard let meeting, let sourceID = task.sourceSegmentID else { return [] }
        return meeting.segments.segments(around: sourceID, lead: Self.contextWindow, trail: Self.contextWindow)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    taskBlock
                    if let meeting {
                        meetingBlock(meeting)
                    }
                    if !contextSegments.isEmpty {
                        contextBlock
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 640)
    }

    private var header: some View {
        HStack {
            Label("Task Details", systemImage: "checkmark.circle")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var taskBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
                Text(task.text)
                    .font(.title3.weight(.semibold))
                    .strikethrough(task.isCompleted)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if let priority = task.priority, !task.isCompleted, !task.isDismissed {
                    TaskPriorityBadge(priority: priority)
                }
                if let assignee = task.displayAssignee {
                    Label(assignee, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Unassigned", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let due = task.dueDate {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Label("Created \(task.createdAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if task.isDismissed, let note = task.dismissalNote {
                Label("Won't Do — \(note)", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func meetingBlock(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source Meeting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(meeting.title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation Context")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(contextSegments) { segment in
                    contextRow(segment)
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func contextRow(_ segment: TranscriptSegment) -> some View {
        let isSource = segment.id == task.sourceSegmentID
        let nameStyle: AnyShapeStyle = isSource ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
        let textStyle: AnyShapeStyle = isSource ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        let bgStyle: AnyShapeStyle = isSource ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.speaker.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(nameStyle)
                Text(segment.formattedTimestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 80, alignment: .leading)
            Text(segment.text)
                .font(.callout)
                .foregroundStyle(textStyle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(bgStyle, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                // TODO: implement JIRA ticket draft + preview + create flow.
            } label: {
                Label("Generate JIRA Ticket", systemImage: "ticket")
            }
            .disabled(true)
            .help("Coming soon — will draft a JIRA ticket from this task and the surrounding meeting context")
            Spacer()
        }
        .padding(16)
    }
}
