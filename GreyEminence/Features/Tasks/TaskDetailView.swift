import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Bindable var task: ActionItem
    @Environment(\.dismiss) private var dismiss

    private var meeting: Meeting? { task.meeting }

    private var summarySections: [SummarySection] {
        guard let raw = meeting?.latestInsight?.summary else { return [] }
        return SummarySection.parse(raw) ?? []
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
                    if !summarySections.isEmpty {
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
            Text("Meeting Summary")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(summarySections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                        if let intro = section.intro, !intro.isEmpty {
                            Text(intro)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(section.points.enumerated()), id: \.offset) { _, pt in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pt.label)
                                        .font(.caption.weight(.semibold))
                                    Text(pt.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
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
