import SwiftUI
import SwiftData

struct ContactChip: View {
    let contact: Contact
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(contact.initials)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(contact.avatarColor.gradient, in: Circle())

            Text(contact.displayNickname)
                .font(.caption)
                .lineLimit(1)
                .help(contact.name)
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .contextMenu {
            if let onRemove {
                Button("Remove", role: .destructive) {
                    onRemove()
                }
            }
        }
    }
}

struct CompactContactDot: View {
    let contact: Contact
    var onRemove: (() -> Void)?

    var body: some View {
        Text(contact.initials)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(contact.avatarColor.gradient, in: Circle())
            .help(contact.name)
            .contextMenu {
                if let onRemove {
                    Button("Remove", role: .destructive) {
                        onRemove()
                    }
                }
            }
    }
}

struct MeetingAttendeesRow: View {
    @Bindable var meeting: Meeting
    @State private var showPicker = false

    private var excludedIDs: Set<PersistentIdentifier> {
        Set(meeting.attendees.map(\.persistentModelID))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)

            if meeting.attendees.isEmpty {
                Text("No attendees")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let sorted = meeting.attendees.sorted { $0.name < $1.name }
                let compact = sorted.count > 4
                ForEach(sorted) { contact in
                    if compact {
                        CompactContactDot(contact: contact) {
                            meeting.attendees.removeAll { $0.id == contact.id }
                        }
                    } else {
                        ContactChip(contact: contact) {
                            meeting.attendees.removeAll { $0.id == contact.id }
                        }
                    }
                }
            }

            Button {
                showPicker.toggle()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker) {
                ContactPicker(excludedContacts: excludedIDs) { contact in
                    meeting.attendees.append(contact)
                    showPicker = false
                }
            }
        }
    }
}
