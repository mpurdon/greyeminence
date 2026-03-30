import SwiftUI
import SwiftData

struct AddCandidateSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \InterviewRole.createdAt) private var roles: [InterviewRole]
    @State private var name = ""
    @State private var email = ""
    @State private var selectedRole: InterviewRole?
    @FocusState private var focusedField: Field?

    private enum Field { case name, email }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Candidate")
                .font(.headline)
                .padding()

            Form {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                TextField("Email (optional)", text: $email)
                    .focused($focusedField, equals: .email)
                Picker("Role (optional)", selection: $selectedRole) {
                    Text("None").tag(nil as InterviewRole?)
                    ForEach(roles) { role in
                        Text(role.fullDescription).tag(role as InterviewRole?)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 170)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add & Create Another") {
                    saveCandidate()
                    resetForm()
                }
                .disabled(trimmedName.isEmpty)
                Button("Add") {
                    saveCandidate()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
            .padding()
        }
        .frame(width: 400)
        .onAppear { focusedField = .name }
    }

    private func saveCandidate() {
        let candidate = Candidate(
            name: trimmedName,
            email: email.isEmpty ? nil : email.trimmingCharacters(in: .whitespaces)
        )
        candidate.role = selectedRole
        modelContext.insert(candidate)
    }

    private func resetForm() {
        name = ""
        email = ""
        focusedField = .name
    }
}
