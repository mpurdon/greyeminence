import SwiftUI
import SwiftData

struct InterviewListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Interview.createdAt, order: .reverse) private var interviews: [Interview]
    @Binding var selectedInterview: Interview?
    @Binding var showInspector: Bool
    @Binding var inspectorWidth: CGFloat?
    @State private var searchText = ""

    private var filteredInterviews: [Interview] {
        let active = interviews.filter { $0.status != .archived }
        if searchText.isEmpty { return active }
        let query = searchText.lowercased()
        return active.filter {
            ($0.candidate?.name.lowercased().contains(query) ?? false) ||
            ($0.candidate?.role?.displayTitle.lowercased().contains(query) ?? false) ||
            ($0.rubric?.name.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredInterviews, selection: $selectedInterview) { interview in
                InterviewRowView(interview: interview)
                    .tag(interview)
                    .contextMenu {
                        if interview.status == .completed {
                            Button("Archive") {
                                interview.status = .archived
                            }
                        }
                        Button("Delete", role: .destructive) {
                            if selectedInterview == interview { selectedInterview = nil }
                            modelContext.delete(interview)
                        }
                    }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search interviews")
            .navigationTitle("Interviews")
            .navigationSplitViewColumnWidth(min: 280, ideal: 300)
            .overlay {
                if interviews.isEmpty {
                    ContentUnavailableView(
                        "No Interviews",
                        systemImage: "person.badge.shield.checkmark",
                        description: Text("Start an interview from the setup view")
                    )
                } else if filteredInterviews.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        } detail: {
            if let interview = selectedInterview {
                InterviewDetailPlaceholder(interview: interview)
            } else {
                ContentUnavailableView(
                    "No Interview Selected",
                    systemImage: "person.badge.shield.checkmark",
                    description: Text("Select an interview to view the scorecard")
                )
            }
        }
    }
}

// MARK: - Row View

private struct InterviewRowView: View {
    let interview: Interview

    var body: some View {
        HStack(spacing: 10) {
            // Candidate avatar
            if let candidate = interview.candidate {
                Text(candidate.initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(candidate.avatarColor.gradient, in: Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.gray.gradient, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(interview.candidate?.name ?? "Unknown Candidate")
                        .font(.body)

                    if let rec = interview.overallRecommendation {
                        Text(rec.shortLabel)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(rec.color.opacity(0.2), in: Capsule())
                            .foregroundStyle(rec.color)
                    }
                }

                HStack(spacing: 6) {
                    if let role = interview.candidate?.role {
                        Text(role.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(interview.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let gp = interview.compositeGradePoints {
                    let grade = LetterGrade.from(gradePoints: gp)
                    Text("Grade: \(grade.label)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Placeholder Detail (until scorecard is built)

private struct InterviewDetailPlaceholder: View {
    let interview: Interview

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(interview.candidate?.name ?? "Interview")
                .font(.title2.weight(.semibold))
            if let rubric = interview.rubric {
                Text("Rubric: \(rubric.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Status: \(interview.status.rawValue.capitalized)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Scorecard coming soon")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
