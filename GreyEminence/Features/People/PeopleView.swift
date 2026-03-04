import SwiftUI
import SwiftData

struct PeopleView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Contact.name) private var contacts: [Contact]
    @State private var selectedContact: Contact?
    @State private var showAddSheet = false
    @State private var searchText = ""

    private var filteredContacts: [Contact] {
        if searchText.isEmpty { return contacts }
        let query = searchText.lowercased()
        return contacts.filter {
            $0.name.lowercased().contains(query) ||
            ($0.email?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredContacts, selection: $selectedContact) { contact in
                ContactRowView(contact: contact)
                    .tag(contact)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            if selectedContact == contact {
                                selectedContact = nil
                            }
                            modelContext.delete(contact)
                        }
                    }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search contacts")
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Contact", systemImage: "plus")
                    }
                }
            }
            .overlay {
                if contacts.isEmpty {
                    ContentUnavailableView(
                        "No Contacts",
                        systemImage: "person.2",
                        description: Text("Add contacts to assign them to meetings and action items")
                    )
                } else if filteredContacts.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddContactSheet()
            }
        } detail: {
            if let contact = selectedContact {
                ContactDetailView(contact: contact)
            } else {
                ContentUnavailableView(
                    "No Contact Selected",
                    systemImage: "person",
                    description: Text("Select a contact to view details")
                )
            }
        }
    }
}
