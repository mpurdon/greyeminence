import SwiftUI
import SwiftData

struct AddContactSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Contact")
                .font(.headline)
                .padding()

            Form {
                TextField("Name", text: $name)
                TextField("Email (optional)", text: $email)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 120)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    let contact = Contact(
                        name: name.trimmingCharacters(in: .whitespaces),
                        email: email.isEmpty ? nil : email.trimmingCharacters(in: .whitespaces)
                    )
                    modelContext.insert(contact)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 360)
    }
}
