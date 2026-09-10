import SwiftUI
import SwiftData

/// What a chip or dot can do to its person. Attendance is a toggle, not a
/// removal: an invitee who never joined stays listed as invited and drops
/// out of the roster the AI, the voice matcher and task assignment use.
struct AttendeeActions {
    var isAbsent: Bool
    var onToggleAbsent: () -> Void
    var onRemove: () -> Void
}

private struct AttendeeMenu: View {
    let contact: Contact
    let actions: AttendeeActions

    var body: some View {
        Button(actions.isAbsent ? "Mark as Attended" : "Did Not Attend") {
            actions.onToggleAbsent()
        }
        Divider()
        Button("Remove from Meeting", role: .destructive) {
            actions.onRemove()
        }
    }
}

/// The initials circle. Absence reads as faded and colourless — still there,
/// plainly not in the room.
private struct InitialsDot: View {
    let contact: Contact
    var isAbsent: Bool = false

    var body: some View {
        Text(contact.initials)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(contact.avatarColor.gradient, in: Circle())
            .saturation(isAbsent ? 0 : 1)
            .opacity(isAbsent ? 0.35 : 1)
    }
}

struct ContactChip: View {
    let contact: Contact
    var actions: AttendeeActions?

    var body: some View {
        HStack(spacing: 4) {
            InitialsDot(contact: contact, isAbsent: actions?.isAbsent ?? false)
            Text(contact.displayNickname)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(actions?.isAbsent ?? false, color: .secondary)
                .foregroundStyle(actions?.isAbsent ?? false ? .secondary : .primary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(contact.attendeeTooltip(absent: actions?.isAbsent ?? false))
        .contextMenu {
            if let actions { AttendeeMenu(contact: contact, actions: actions) }
        }
    }
}

/// A dot with no `.help`: the system tooltip takes a second to appear and
/// often never does when the pointer moves between adjacent dots. The name
/// is reported through `onHover` instead and drawn by the row, instantly.
struct CompactContactDot: View {
    let contact: Contact
    var actions: AttendeeActions?
    var onHover: ((Bool) -> Void)?

    var body: some View {
        InitialsDot(contact: contact, isAbsent: actions?.isAbsent ?? false)
            .contentShape(Circle())
            .onHover { onHover?($0) }
            .contextMenu {
                if let actions { AttendeeMenu(contact: contact, actions: actions) }
            }
    }
}

extension Contact {
    /// Name plus email, unless the "name" *is* the email (calendar invites for
    /// people who aren't in Contacts often come through that way).
    var attendeeTooltip: String {
        attendeeTooltip(absent: false)
    }

    func attendeeTooltip(absent: Bool) -> String {
        var text = name
        if let email, !email.isEmpty, email.lowercased() != name.lowercased() {
            text += " · \(email)"
        }
        if absent { text += " · did not attend" }
        return text
    }
}

/// Everyone, one per line, with what can be done to them. Sits under the
/// dot row when expanded, so a twenty-person invite is readable without
/// hovering twenty circles.
private struct AttendeeList: View {
    let contacts: [Contact]
    let actions: (Contact) -> AttendeeActions

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(contacts) { contact in
                AttendeeListRow(contact: contact, actions: actions(contact))
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 20)
    }
}

private struct AttendeeListRow: View {
    let contact: Contact
    let actions: AttendeeActions

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            InitialsDot(contact: contact, isAbsent: actions.isAbsent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(contact.name)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(actions.isAbsent ? .secondary : .primary)
                    if actions.isAbsent {
                        Text("did not attend")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let email = contact.email,
                   !email.isEmpty,
                   email.lowercased() != contact.name.lowercased() {
                    Text(email)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isHovering {
                Button(actions.isAbsent ? "Attended" : "Did not attend") {
                    actions.onToggleAbsent()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)

                Button {
                    actions.onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(contact.name) from this meeting")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.secondary.opacity(0.15) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu { AttendeeMenu(contact: contact, actions: actions) }
    }
}

struct MeetingAttendeesRow: View {
    @Bindable var meeting: Meeting
    @State private var showPicker = false
    @State private var isExpanded = false
    @State private var hovered: Contact?

    /// Present people first, then the absent, each group by name — so the
    /// faded dots gather at the end instead of breaking up the roster.
    private var attendees: [Contact] {
        meeting.attendees.sorted { left, right in
            let leftAbsent = meeting.isAbsent(left), rightAbsent = meeting.isAbsent(right)
            if leftAbsent != rightAbsent { return !leftAbsent }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private var excludedIDs: Set<PersistentIdentifier> {
        Set(meeting.attendees.map(\.persistentModelID))
    }

    var body: some View {
        let people = attendees
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if people.isEmpty {
                    Text("No attendees")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    roster(people)
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
                        // Stay open so the user can add several attendees in one
                        // pass; click outside (or hit Escape) to dismiss.
                    }
                }

                if people.count > Self.chipLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide the list" : "List everyone by name")
                }

                // The hover readout. Instant, because it is plain state, and
                // never clipped, because it is inline rather than floating.
                if let hovered {
                    Text(hovered.attendeeTooltip(absent: meeting.isAbsent(hovered)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }

            if isExpanded, people.count > Self.chipLimit {
                AttendeeList(contacts: people, actions: actions)
            }
        }
    }

    /// Full-name chips up to this headcount; past it the row shows initials.
    private static let chipLimit = 4

    /// Chips or dots — chosen from the headcount alone, never by measuring
    /// (a `ViewThatFits` here once cost most of the main thread). Every dot
    /// is shown; a `FlowLayout` wraps them rather than an overflow pill
    /// hiding the tail, and the expanding list below carries the names.
    @ViewBuilder
    private func roster(_ people: [Contact]) -> some View {
        if people.count <= Self.chipLimit {
            HStack(spacing: 6) {
                ForEach(people) { contact in
                    ContactChip(contact: contact, actions: actions(contact))
                }
            }
        } else {
            FlowLayout(spacing: 3, rowAlignment: .center) {
                ForEach(people) { contact in
                    CompactContactDot(contact: contact, actions: actions(contact)) { inside in
                        if inside {
                            hovered = contact
                        } else if hovered?.id == contact.id {
                            hovered = nil
                        }
                    }
                }
            }
        }
    }

    private func actions(_ contact: Contact) -> AttendeeActions {
        AttendeeActions(
            isAbsent: meeting.isAbsent(contact),
            onToggleAbsent: { meeting.setAbsent(contact, !meeting.isAbsent(contact)) },
            onRemove: { remove(contact) }
        )
    }

    private func remove(_ contact: Contact) {
        if hovered?.id == contact.id { hovered = nil }
        meeting.setAbsent(contact, false)
        meeting.attendees.removeAll { $0.id == contact.id }
    }
}
