import SwiftUI
import SwiftData

struct ContactPicker: View {
    @Query(sort: \Contact.name) private var allContacts: [Contact]
    @State private var searchText = ""
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
            TextField("Search contacts...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            if filteredContacts.isEmpty {
                Text(allContacts.isEmpty ? "No contacts yet" : "No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredContacts) { contact in
                            Button {
                                onSelect(contact)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(contact.initials)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(contact.avatarColor.gradient, in: Circle())

                                    Text(contact.name)
                                        .font(.body)

                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(width: 240)
    }
}
