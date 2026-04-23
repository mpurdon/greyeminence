import SwiftUI
import SwiftData

struct MeetingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Binding var selectedMeeting: Meeting?

    private var groupedMeetings: [(String, [Meeting])] {
        let calendar = Calendar.current
        let regularMeetings = meetings.filter { !$0.isInterviewMeeting }
        let grouped = Dictionary(grouping: regularMeetings) { meeting -> String in
            if calendar.isDateInToday(meeting.date) {
                return "Today"
            } else if calendar.isDateInYesterday(meeting.date) {
                return "Yesterday"
            } else if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: .now),
                      weekInterval.contains(meeting.date) {
                return "This Week"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM yyyy"
                return formatter.string(from: meeting.date)
            }
        }
        let order = ["Today", "Yesterday", "This Week"]
        return grouped.sorted { a, b in
            let aIdx = order.firstIndex(of: a.key) ?? Int.max
            let bIdx = order.firstIndex(of: b.key) ?? Int.max
            if aIdx != bIdx { return aIdx < bIdx }
            return a.key > b.key
        }
    }

    private func deleteMeeting(_ meeting: Meeting) {
        if selectedMeeting == meeting {
            selectedMeeting = nil
        }
        MeetingDeletion.delete(meeting, in: modelContext, allMeetings: meetings)
    }

    var body: some View {
        List(selection: $selectedMeeting) {
            ForEach(groupedMeetings, id: \.0) { section, sectionMeetings in
                Section {
                    ForEach(sectionMeetings) { meeting in
                        MeetingRowView(meeting: meeting)
                            .tag(meeting)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteMeeting(meeting)
                                } label: {
                                    Label("Delete Meeting", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            deleteMeeting(sectionMeetings[index])
                        }
                    }
                } header: {
                    Text(section)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Meetings")
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView(
                    "No Meetings Yet",
                    systemImage: "waveform",
                    description: Text("Start a recording to create your first meeting")
                )
            }
        }
    }
}
