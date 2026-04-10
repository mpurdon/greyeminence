import SwiftUI
import SwiftData

struct MyProfileSetupSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("myContactID") private var myContactIDString = ""
    @Query(sort: \Contact.name) private var contacts: [Contact]

    @State private var selectedContactID: String = ""
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var mode: Mode = .select

    enum Mode { case select, create }

    private var activeContacts: [Contact] {
        contacts.filter { !$0.isArchived }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "person.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("Who are you?")
                    .font(.title3.weight(.semibold))
                Text("Grey Eminence needs to know which contact is you so it can attribute \"Me\" in transcripts to the right person.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding()

            Form {
                if mode == .select && !activeContacts.isEmpty {
                    Picker("Select yourself", selection: $selectedContactID) {
                        Text("Choose...").tag("")
                        ForEach(activeContacts) { contact in
                            HStack {
                                Text(contact.name)
                                if let email = contact.email {
                                    Text(email).foregroundStyle(.secondary)
                                }
                            }
                            .tag(contact.id.uuidString)
                        }
                    }

                    Button("Or create a new contact") {
                        mode = .create
                    }
                    .font(.caption)
                } else {
                    TextField("Your name", text: $newName)
                    TextField("Your email (optional)", text: $newEmail)

                    if !activeContacts.isEmpty {
                        Button("Select an existing contact instead") {
                            mode = .select
                        }
                        .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: mode == .select && !activeContacts.isEmpty ? 140 : 150)

            HStack {
                Button("Skip for Now") {
                    dismiss()
                }

                Spacer()

                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear {
            // Auto-detect contact with nickname "Me" or "me"
            if let meContact = contacts.first(where: {
                $0.nickname?.lowercased() == "me" || $0.name.lowercased() == "me"
            }) {
                selectedContactID = meContact.id.uuidString
            }

            if activeContacts.isEmpty {
                mode = .create
            }
        }
    }

    private var canSave: Bool {
        if mode == .select {
            return !selectedContactID.isEmpty
        } else {
            return !newName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        if mode == .select {
            myContactIDString = selectedContactID
        } else {
            let contact = Contact(
                name: newName.trimmingCharacters(in: .whitespaces),
                email: newEmail.isEmpty ? nil : newEmail.trimmingCharacters(in: .whitespaces)
            )
            contact.isInterviewer = true
            modelContext.insert(contact)
            PersistenceGate.save(modelContext, site: "MyProfileSetupSheet.saveProfile")
            myContactIDString = contact.id.uuidString
        }
    }
}
