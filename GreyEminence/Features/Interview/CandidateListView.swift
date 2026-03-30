import SwiftUI
import SwiftData

struct CandidateListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Candidate.name) private var candidates: [Candidate]
    @State private var selectedCandidate: Candidate?
    @State private var showAddSheet = false
    @State private var showArchived = false
    @State private var searchText = ""

    private var filteredCandidates: [Candidate] {
        let visible = candidates.filter { showArchived || !$0.isArchived }
        if searchText.isEmpty { return visible }
        let query = searchText.lowercased()
        return visible.filter {
            $0.name.lowercased().contains(query) ||
            ($0.email?.lowercased().contains(query) ?? false) ||
            ($0.role?.displayTitle.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredCandidates, selection: $selectedCandidate) { candidate in
                CandidateRowView(candidate: candidate)
                    .tag(candidate)
                    .opacity(candidate.isArchived ? 0.5 : 1)
                    .contextMenu {
                        Button(candidate.isArchived ? "Unarchive" : "Archive") {
                            candidate.isArchived.toggle()
                        }
                        Button("Delete", role: .destructive) {
                            if selectedCandidate == candidate { selectedCandidate = nil }
                            modelContext.delete(candidate)
                        }
                    }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search candidates")
            .navigationTitle("Candidates")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSheet = true } label: {
                        Label("Add Candidate", systemImage: "plus")
                    }
                }
                ToolbarItem {
                    Toggle(isOn: $showArchived) {
                        Label("Show Archived", systemImage: "archivebox")
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Candidates",
                        systemImage: "person.badge.plus",
                        description: Text("Add candidates to track interviews")
                    )
                } else if filteredCandidates.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddCandidateSheet()
            }
        } detail: {
            if let candidate = selectedCandidate {
                CandidateDetailView(candidate: candidate)
            } else {
                ContentUnavailableView(
                    "No Candidate Selected",
                    systemImage: "person",
                    description: Text("Select a candidate to view details")
                )
            }
        }
    }
}

private struct CandidateRowView: View {
    let candidate: Candidate

    var body: some View {
        HStack(spacing: 10) {
            Text(candidate.initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(candidate.avatarColor.gradient, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.body)
                if let role = candidate.role {
                    Text(role.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !candidate.interviews.isEmpty {
                Text("\(candidate.interviews.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.cyan.opacity(0.15), in: Capsule())
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.vertical, 2)
    }
}
