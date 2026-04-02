import SwiftUI
import SwiftData

struct RubricListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Rubric.createdAt, order: .reverse) private var rubrics: [Rubric]
    @State private var selectedRubric: Rubric?
    @State private var showAddSheet = false
    @State private var searchText = ""
    @State private var showArchived = false

    private var filteredRubrics: [Rubric] {
        let visible = rubrics.filter { showArchived || !$0.isArchived }
        if searchText.isEmpty { return visible }
        let query = searchText.lowercased()
        return visible.filter {
            $0.name.lowercased().contains(query) ||
            ($0.role?.displayTitle.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredRubrics, selection: $selectedRubric) { rubric in
                RubricRowView(rubric: rubric)
                    .tag(rubric)
                    .opacity(rubric.isArchived ? 0.5 : 1)
                    .contextMenu {
                        Button(rubric.isArchived ? "Unarchive" : "Archive") {
                            rubric.isArchived.toggle()
                        }
                        Button("Duplicate") {
                            duplicateRubric(rubric)
                        }
                        Button("Delete", role: .destructive) {
                            if selectedRubric == rubric { selectedRubric = nil }
                            modelContext.delete(rubric)
                        }
                    }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search rubrics")
            .navigationTitle("Rubrics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSheet = true } label: {
                        Label("Add Rubric", systemImage: "plus")
                    }
                }
                ToolbarItem {
                    Toggle(isOn: $showArchived) {
                        Label("Show Archived", systemImage: "archivebox")
                    }
                    .help(showArchived ? "Hide archived" : "Show archived")
                }
            }
            .overlay {
                if rubrics.isEmpty {
                    ContentUnavailableView(
                        "No Rubrics",
                        systemImage: "list.clipboard",
                        description: Text("Create rubrics to evaluate interview candidates")
                    )
                } else if filteredRubrics.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddRubricSheet { rubric in
                    selectedRubric = rubric
                }
            }
        } detail: {
            if let rubric = selectedRubric {
                RubricEditorView(rubric: rubric)
            } else {
                ContentUnavailableView(
                    "No Rubric Selected",
                    systemImage: "list.clipboard",
                    description: Text("Select a rubric to edit")
                )
            }
        }
    }

    private func duplicateRubric(_ source: Rubric) {
        let copy = Rubric(name: "\(source.name) (Copy)")
        copy.role = source.role
        modelContext.insert(copy)
        deepCopyRubricContents(from: source, to: copy)
        selectedRubric = copy
    }
}

// MARK: - Row View

private struct RubricRowView: View {
    let rubric: Rubric

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rubric.name)
                .font(.body)
            HStack(spacing: 6) {
                if let role = rubric.role {
                    Text(role.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(rubric.sections.count) sections")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Sheet

private struct AddRubricSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \InterviewRole.createdAt) private var roles: [InterviewRole]
    @Query(sort: \Rubric.createdAt, order: .reverse) private var existingRubrics: [Rubric]
    @State private var name = ""
    @State private var selectedRole: InterviewRole?
    @State private var sourceRubric: Rubric?
    var onCreated: (Rubric) -> Void

    private var defaultName: String {
        guard let role = selectedRole else { return "Interview Rubric" }
        return "\(role.displayTitle) Interview"
    }

    private var activeRubrics: [Rubric] {
        existingRubrics.filter { !$0.isArchived }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Rubric")
                .font(.headline)
                .padding()

            Form {
                Picker("Role", selection: $selectedRole) {
                    Text("Select a role...").tag(nil as InterviewRole?)
                    ForEach(roles) { role in
                        Text(role.fullDescription).tag(role as InterviewRole?)
                    }
                }
                TextField("Name (optional)", text: $name, prompt: Text(defaultName))
                Picker("Copy from (optional)", selection: $sourceRubric) {
                    Text("Start blank").tag(nil as Rubric?)
                    ForEach(activeRubrics) { rubric in
                        Text(rubric.name).tag(rubric as Rubric?)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 180)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    let rubric = Rubric(name: trimmed.isEmpty ? defaultName : trimmed)
                    rubric.role = selectedRole
                    modelContext.insert(rubric)
                    if let source = sourceRubric {
                        deepCopyRubricContents(from: source, to: rubric)
                    }
                    onCreated(rubric)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRole == nil)
            }
            .padding()
        }
        .frame(width: 400)
    }

}

// MARK: - Shared Deep Copy

private func deepCopyRubricContents(from source: Rubric, to target: Rubric) {
    for section in source.sections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
        let newSection = RubricSection(
            title: section.title,
            description: section.sectionDescription,
            sortOrder: section.sortOrder,
            weight: section.weight
        )
        newSection.rubric = target
        for criterion in section.criteria.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let newCriterion = RubricCriterion(
                signal: criterion.signal,
                sortOrder: criterion.sortOrder,
                evaluationNotes: criterion.evaluationNotes
            )
            newCriterion.section = newSection
        }
        for signal in section.bonusSignals.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let newSignal = RubricBonusSignal(
                label: signal.label,
                expectedAnswer: signal.expectedAnswer,
                bonusValue: signal.bonusValue,
                sortOrder: signal.sortOrder
            )
            newSignal.section = newSection
        }
    }
}
