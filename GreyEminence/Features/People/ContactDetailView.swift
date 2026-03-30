import SwiftUI
import SwiftData

struct ContactDetailView: View {
    @Bindable var contact: Contact
    @AppStorage("stalledThresholdDays") private var stalledThresholdDays = 7

    var body: some View {
        List {
            if contact.isArchived {
                Section {
                    Label("This contact is archived and won't appear in pickers.", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                TextField("Name", text: $contact.name)
                TextField("Nickname", text: Binding(
                    get: { contact.nickname ?? contact.firstName },
                    set: { new in
                        let trimmed = new.trimmingCharacters(in: .whitespaces)
                        contact.nickname = trimmed == contact.firstName ? nil : (trimmed.isEmpty ? nil : trimmed)
                    }
                ), prompt: Text(contact.firstName))
                TextField("Email", text: Binding(
                    get: { contact.email ?? "" },
                    set: { contact.email = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Interviewer", isOn: $contact.isInterviewer)
            }

            if !contact.meetings.isEmpty {
                Section("Meetings (\(contact.meetings.count))") {
                    ForEach(sortedMeetings) { meeting in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(.body)
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !contact.assignedActionItems.isEmpty {
                Section {
                    if let rate = commitmentService.completionRate(for: contact) {
                        HStack {
                            Text("Completion Rate")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", rate * 100))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(rate >= 0.7 ? .green : .orange)
                        }
                    }

                    ForEach(contact.assignedActionItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCompleted ? .green : .secondary)
                            Text(item.text)
                                .strikethrough(item.isCompleted)
                                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        }
                    }
                } header: {
                    Text("Commitments (\(contact.assignedActionItems.count))")
                }

                let stalled = commitmentService.stalledCommitments(for: contact, threshold: stalledThresholdDays)
                if !stalled.isEmpty {
                    Section("Stalled (\(stalled.count))") {
                        ForEach(stalled) { item in
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(item.daysStalled > 14 ? .red : .orange)
                                Text(item.actionItem.text)
                                    .font(.body)
                                Spacer()
                                Text("\(item.daysStalled)d")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(contact.name)
        .toolbar {
            ToolbarItem {
                Button {
                    contact.isArchived.toggle()
                } label: {
                    Label(
                        contact.isArchived ? "Unarchive" : "Archive",
                        systemImage: contact.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                .help(contact.isArchived ? "Unarchive this contact" : "Archive this contact")
            }
        }
    }

    private let commitmentService = CommitmentTrackingService()

    private var sortedMeetings: [Meeting] {
        contact.meetings.sorted { $0.date > $1.date }
    }
}
