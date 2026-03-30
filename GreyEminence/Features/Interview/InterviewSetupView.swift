import SwiftUI
import SwiftData

struct InterviewSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Candidate.name) private var candidates: [Candidate]
    @Query(sort: \Rubric.createdAt, order: .reverse) private var rubrics: [Rubric]
    @Query(sort: \Contact.name) private var contacts: [Contact]

    var interviewViewModel: InterviewRecordingViewModel

    @State private var selectedCandidate: Candidate?
    @State private var selectedRubric: Rubric?
    @State private var selectedInterviewers: Set<UUID> = []
    @State private var preNotes: String = ""
    @State private var showAddCandidate = false

    private var activeCandidates: [Candidate] {
        candidates.filter { !$0.isArchived }
    }

    private var activeInterviewers: [Contact] {
        contacts.filter { !$0.isArchived && $0.isInterviewer }
    }

    private var activeRubrics: [Rubric] {
        rubrics.filter { !$0.isArchived }
    }

    private var filteredRubrics: [Rubric] {
        guard let role = selectedCandidate?.role else { return activeRubrics }
        let matching = activeRubrics.filter { $0.role?.id == role.id }
        return matching.isEmpty ? activeRubrics : matching
    }

    private var canStart: Bool {
        selectedCandidate != nil && selectedRubric != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "person.badge.shield.checkmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.cyan)
                    Text("Interview Setup")
                        .font(.title2.weight(.semibold))
                    Text("Configure the interview before recording")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Form
                Form {
                    Section("Candidate") {
                        HStack {
                            Picker("Candidate", selection: $selectedCandidate) {
                                Text("Select...").tag(nil as Candidate?)
                                ForEach(activeCandidates) { candidate in
                                    HStack {
                                        Text(candidate.name)
                                        if let role = candidate.role {
                                            Text("(\(role.displayTitle))")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(candidate as Candidate?)
                                }
                            }
                            Button {
                                showAddCandidate = true
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section("Rubric") {
                        Picker("Rubric", selection: $selectedRubric) {
                            Text("Select...").tag(nil as Rubric?)
                            ForEach(filteredRubrics) { rubric in
                                VStack(alignment: .leading) {
                                    Text(rubric.name)
                                    if let role = rubric.role {
                                        Text(role.displayTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(rubric as Rubric?)
                            }
                        }
                        if let rubric = selectedRubric {
                            Text("\(rubric.sections.count) sections")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if activeInterviewers.isEmpty {
                            Text("No interviewers configured. Mark contacts as interviewers in People.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(activeInterviewers) { contact in
                                Toggle(isOn: Binding(
                                    get: { selectedInterviewers.contains(contact.id) },
                                    set: { isOn in
                                        if isOn {
                                            selectedInterviewers.insert(contact.id)
                                        } else {
                                            selectedInterviewers.remove(contact.id)
                                        }
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        Text(contact.initials)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 18, height: 18)
                                            .background(contact.avatarColor.gradient, in: Circle())
                                        Text(contact.name)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    } header: {
                        Text("Other Interviewers")
                    } footer: {
                        Text("You are always included as an interviewer.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Section("Pre-Interview Notes") {
                        TextEditor(text: $preNotes)
                            .frame(minHeight: 50)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(maxWidth: 500, maxHeight: 500)

                // Start button
                Button {
                    startInterview()
                } label: {
                    Label("Start Interview", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!canStart)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showAddCandidate) {
            AddCandidateSheet()
        }
        .onChange(of: selectedCandidate) { _, candidate in
            // Auto-select rubric if candidate has a role with rubrics
            if let role = candidate?.role,
               let rubric = activeRubrics.first(where: { $0.role?.id == role.id }) {
                selectedRubric = rubric
            }
        }
    }

    private func startInterview() {
        guard let candidate = selectedCandidate,
              let rubric = selectedRubric else { return }

        let interviewerContacts = activeInterviewers.filter { selectedInterviewers.contains($0.id) }

        interviewViewModel.startInterview(
            candidate: candidate,
            rubric: rubric,
            interviewers: interviewerContacts,
            notes: preNotes.isEmpty ? nil : preNotes,
            in: modelContext
        )
    }
}
