import SwiftUI
import SwiftData

struct ContactDetailView: View {
    @Bindable var contact: Contact

    var body: some View {
        List {
            Section("Details") {
                TextField("Name", text: $contact.name)
                TextField("Email", text: Binding(
                    get: { contact.email ?? "" },
                    set: { contact.email = $0.isEmpty ? nil : $0 }
                ))
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

                let stalled = commitmentService.stalledCommitments(for: contact)
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
    }

    private let commitmentService = CommitmentTrackingService()

    private var sortedMeetings: [Meeting] {
        contact.meetings.sorted { $0.date > $1.date }
    }
}
