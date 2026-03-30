import SwiftUI
import SwiftData

struct RubricEditorView: View {
    @Bindable var rubric: Rubric
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InterviewRole.createdAt) private var roles: [InterviewRole]

    private var sortedSections: [RubricSection] {
        rubric.sections.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        List {
            // Header
            Section("Rubric Details") {
                TextField("Name", text: $rubric.name)
                Picker("Role", selection: Binding(
                    get: { rubric.role },
                    set: { rubric.role = $0 }
                )) {
                    Text("None").tag(nil as InterviewRole?)
                    ForEach(roles) { role in
                        Text(role.fullDescription).tag(role as InterviewRole?)
                    }
                }
            }

            // Sections
            ForEach(sortedSections) { section in
                RubricSectionEditorView(section: section, onDelete: {
                    rubric.sections.removeAll { $0.id == section.id }
                    modelContext.delete(section)
                })
            }

            // Add section button
            Section {
                Button {
                    addSection()
                } label: {
                    Label("Add Section", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle(rubric.name)
    }

    private func addSection() {
        let section = RubricSection(
            title: "New Section",
            description: "",
            sortOrder: rubric.sections.count,
            weight: 1.0
        )
        section.rubric = rubric
        rubric.sections.append(section)
    }
}
