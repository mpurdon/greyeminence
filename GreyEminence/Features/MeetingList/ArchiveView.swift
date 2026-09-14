import SwiftUI
import SwiftData

/// Long-tail meeting browser. The recent list (MeetingListView) only carries
/// the current month plus two priors so it stays scannable as the meeting
/// count grows. Everything older lives here, behind search + filters, grouped
/// by quarter so users don't scroll past hundreds of identical-looking rows.
struct ArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]
    @Binding var selectedMeeting: Meeting?

    @State private var query: String = ""
    @State private var selectedYear: Int? = nil
    @State private var requireInsights = false
    @State private var requireExported = false
    @State private var requireActionItems = false
    @State private var collapsedQuarters: Set<String> = []

    /// Same cutoff as MeetingListView — meetings with date >= cutoff are in
    /// the recent list and don't belong here.
    private static let monthsVisible = 3

    private var cutoffDate: Date {
        let cal = Calendar.current
        let startOfCurrentMonth = cal.dateInterval(of: .month, for: .now)?.start ?? .now
        return cal.date(byAdding: .month, value: -(Self.monthsVisible - 1), to: startOfCurrentMonth) ?? .distantPast
    }

    private var archivedMeetings: [Meeting] {
        let cutoff = cutoffDate
        return allMeetings.filter { !$0.isInterviewMeeting && !$0.isPinned && $0.date < cutoff }
    }

    private var availableYears: [Int] {
        let cal = Calendar.current
        let years = Set(archivedMeetings.map { cal.component(.year, from: $0.date) })
        return years.sorted(by: >)
    }

    private var filteredMeetings: [Meeting] {
        let cal = Calendar.current
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return archivedMeetings.filter { meeting in
            if let year = selectedYear, cal.component(.year, from: meeting.date) != year {
                return false
            }
            if requireInsights && meeting.insights.isEmpty { return false }
            if requireExported && !meeting.isExportedToObsidian { return false }
            if requireActionItems && meeting.pendingActionCount == 0 { return false }
            if !trimmedQuery.isEmpty {
                let titleMatches = meeting.title.lowercased().contains(trimmedQuery)
                let attendeeMatches = meeting.attendees.contains { $0.name.lowercased().contains(trimmedQuery) }
                let summaryMatches = meeting.insights.contains { $0.summary.lowercased().contains(trimmedQuery) }
                if !(titleMatches || attendeeMatches || summaryMatches) { return false }
            }
            return true
        }
    }

    /// Group by calendar quarter — "Q1 2026", "Q4 2025", etc. Quarters scale
    /// gracefully: even with 100 meetings/month, a quarter is ~300 rows worst
    /// case which List virtualizes fine; users typically know roughly when an
    /// old meeting happened to within a quarter.
    private var quarterlyGroups: [(String, [Meeting])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filteredMeetings) { meeting -> String in
            let year = cal.component(.year, from: meeting.date)
            let month = cal.component(.month, from: meeting.date)
            let quarter = (month - 1) / 3 + 1
            return "Q\(quarter) \(year)"
        }
        return grouped.sorted { quarterSortKey($0.key) > quarterSortKey($1.key) }
    }

    /// "Q3 2025" → 2025 * 4 + 3 = 8103. Higher = more recent.
    private func quarterSortKey(_ label: String) -> Int {
        let parts = label.split(separator: " ")
        guard parts.count == 2,
              let q = Int(parts[0].dropFirst()),
              let y = Int(parts[1]) else { return 0 }
        return y * 4 + q
    }

    private var hasActiveFilters: Bool {
        selectedYear != nil || requireInsights || requireExported || requireActionItems || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearFilters() {
        query = ""
        selectedYear = nil
        requireInsights = false
        requireExported = false
        requireActionItems = false
    }

    private func deleteMeeting(_ meeting: Meeting) {
        if selectedMeeting == meeting {
            selectedMeeting = nil
        }
        MeetingDeletion.delete(meeting, in: modelContext, allMeetings: allMeetings)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchAndFilterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.background)
            Divider()
            Group {
                if archivedMeetings.isEmpty {
                    ContentUnavailableView(
                        "Nothing in the archive yet",
                        systemImage: "archivebox",
                        description: Text("Meetings older than three months will appear here.")
                    )
                } else if filteredMeetings.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search term, year, or clear the filters.")
                    )
                } else {
                    meetingList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Archive")
    }

    private var searchAndFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title, attendee, or summary…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // Wraps to multiple rows when the column is narrow so chips stop
            // collapsing into vertical letter stacks. fixedSize on each chip
            // pins the natural width — no mid-word breaks.
            FlowLayout(spacing: 6) {
                yearMenu
                filterChip("Insights", systemImage: "lightbulb", isOn: $requireInsights)
                filterChip("Exported", systemImage: "arrow.up.doc", isOn: $requireExported)
                filterChip("Actions", systemImage: "checkmark.circle", isOn: $requireActionItems)
            }

            HStack(spacing: 8) {
                Text("\(filteredMeetings.count) of \(archivedMeetings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if hasActiveFilters {
                    Button("Clear filters") { clearFilters() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var yearMenu: some View {
        Menu {
            Button("All years") { selectedYear = nil }
            Divider()
            ForEach(availableYears, id: \.self) { year in
                Button {
                    selectedYear = year
                } label: {
                    HStack {
                        Text(String(year))
                        if selectedYear == year {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(selectedYear.map(String.init) ?? "All years")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (selectedYear != nil ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.secondary.opacity(0.10))),
                in: Capsule()
            )
            .foregroundStyle(selectedYear != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func filterChip(_ label: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isOn.wrappedValue ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.secondary.opacity(0.10)),
                in: Capsule()
            )
            .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }

    private var meetingList: some View {
        List(selection: $selectedMeeting) {
            ForEach(quarterlyGroups, id: \.0) { quarter, quarterMeetings in
                Section {
                    if !collapsedQuarters.contains(quarter) {
                        ForEach(quarterMeetings) { meeting in
                            MeetingRowView(meeting: meeting)
                                .tag(meeting)
                                .contextMenu {
                                    MeetingPinButton(meeting: meeting)
                                    Divider()
                                    Button(role: .destructive) {
                                        deleteMeeting(meeting)
                                    } label: {
                                        Label("Delete Meeting", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Button {
                        if collapsedQuarters.contains(quarter) {
                            collapsedQuarters.remove(quarter)
                        } else {
                            collapsedQuarters.insert(quarter)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsedQuarters.contains(quarter) ? "chevron.right" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(quarter)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(quarterMeetings.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
    }
}

