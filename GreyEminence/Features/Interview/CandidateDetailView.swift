import SwiftUI
import SwiftData

struct CandidateDetailView: View {
    @Bindable var candidate: Candidate
    @Query(sort: \InterviewRole.createdAt) private var roles: [InterviewRole]

    var body: some View {
        List {
            if candidate.isArchived {
                Section {
                    Label("This candidate is archived.", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                TextField("Name", text: $candidate.name)
                TextField("Email", text: Binding(
                    get: { candidate.email ?? "" },
                    set: { candidate.email = $0.isEmpty ? nil : $0 }
                ))
                Picker("Role", selection: Binding(
                    get: { candidate.role },
                    set: { candidate.role = $0 }
                )) {
                    Text("None").tag(nil as InterviewRole?)
                    ForEach(roles) { role in
                        Text(role.fullDescription).tag(role as InterviewRole?)
                    }
                }
            }

            Section("Notes") {
                TextEditor(text: Binding(
                    get: { candidate.notes ?? "" },
                    set: { candidate.notes = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 60)
            }

            if !candidate.interviews.isEmpty {
                Section("Interviews (\(candidate.interviews.count))") {
                    ForEach(sortedInterviews) { interview in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(interview.meeting?.title ?? "Interview")
                                        .font(.body)
                                    if let rec = interview.overallRecommendation {
                                        Text(rec.shortLabel)
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(rec.color.opacity(0.2), in: Capsule())
                                            .foregroundStyle(rec.color)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(interview.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let gp = interview.compositeGradePoints {
                                        let grade = LetterGrade.from(gradePoints: gp)
                                        Text(grade.label)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle(candidate.name)
        .toolbar {
            ToolbarItem {
                Button {
                    candidate.isArchived.toggle()
                } label: {
                    Label(
                        candidate.isArchived ? "Unarchive" : "Archive",
                        systemImage: candidate.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
            }
        }
    }

    private var sortedInterviews: [Interview] {
        candidate.interviews.sorted { $0.createdAt > $1.createdAt }
    }
}
