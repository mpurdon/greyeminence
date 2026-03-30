import SwiftUI
import SwiftData

struct AddContactSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nickname = ""
    @State private var email = ""
    @FocusState private var focusedField: Field?

    private enum Field { case name, nickname, email }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Contact")
                .font(.headline)
                .padding()

            Form {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                TextField("Nickname (optional)", text: $nickname)
                    .focused($focusedField, equals: .nickname)
                TextField("Email (optional)", text: $email)
                    .focused($focusedField, equals: .email)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 160)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add & Create Another") {
                    saveContact()
                    resetForm()
                }
                .disabled(trimmedName.isEmpty)

                Button("Add") {
                    saveContact()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
            .padding()
        }
        .frame(width: 360)
        .onAppear { focusedField = .name }
    }

    private func saveContact() {
        let contact = Contact(
            name: trimmedName,
            email: email.isEmpty ? nil : email.trimmingCharacters(in: .whitespaces)
        )
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        if !nick.isEmpty, nick != contact.firstName {
            contact.nickname = nick
        }
        modelContext.insert(contact)
    }

    private func resetForm() {
        name = ""
        nickname = ""
        email = ""
        focusedField = .name
    }
}
