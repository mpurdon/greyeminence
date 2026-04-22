import SwiftUI
import SwiftData

struct ContactPicker: View {
    @Query(sort: \Contact.name) private var allContacts: [Contact]
    @State private var searchText = ""
    @State private var hoveredID: PersistentIdentifier?
    @FocusState private var searchFocused: Bool
    var excludedContacts: Set<PersistentIdentifier>
    var onSelect: (Contact) -> Void

    private var filteredContacts: [Contact] {
        let available = allContacts.filter { !$0.isArchived && !excludedContacts.contains($0.persistentModelID) }
        if searchText.isEmpty { return available }
        let query = searchText.lowercased()
        return available.filter {
            $0.name.lowercased().contains(query) ||
            ($0.nickname?.lowercased().contains(query) ?? false) ||
            ($0.email?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search name or email", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredContacts.first {
                            onSelect(first)
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background.secondary)

            Divider()

            if filteredContacts.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "person.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(allContacts.isEmpty ? "No contacts yet" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredContacts) { contact in
                            row(for: contact)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func row(for contact: Contact) -> some View {
        let isHovered = hoveredID == contact.persistentModelID
        Button {
            onSelect(contact)
        } label: {
            HStack(spacing: 10) {
                Text(contact.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(contact.avatarColor.gradient, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(contact.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let nickname = contact.nickname, !nickname.isEmpty {
                            Text("(\(nickname))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let email = contact.email, !email.isEmpty {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .help(contact.email.flatMap { $0.isEmpty ? nil : "\(contact.name) · \($0)" } ?? contact.name)
        .onHover { hovering in
            hoveredID = hovering ? contact.persistentModelID : nil
        }
    }
}
