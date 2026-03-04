import SwiftUI
import SwiftData

struct DashboardView: View {
    var onMeetingSelected: (Meeting) -> Void = { _ in }

    @Query private var allMeetings: [Meeting]
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted })
    private var pendingActions: [ActionItem]

    private var meetingsThisWeek: [Meeting] {
        let calendar = Calendar.current
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return allMeetings.filter { $0.date >= startOfWeek }
    }

    private var totalRecordingTime: TimeInterval {
        allMeetings.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dashboard")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.horizontal)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 16) {
                    StatCard(
                        title: "This Week",
                        value: "\(meetingsThisWeek.count)",
                        subtitle: "meetings",
                        icon: "calendar",
                        color: .blue
                    )
                    StatCard(
                        title: "Total Meetings",
                        value: "\(allMeetings.count)",
                        subtitle: "all time",
                        icon: "person.2",
                        color: .purple
                    )
                    StatCard(
                        title: "Pending Actions",
                        value: "\(pendingActions.count)",
                        subtitle: "to complete",
                        icon: "checkmark.circle",
                        color: pendingActions.isEmpty ? .green : .orange
                    )
                    StatCard(
                        title: "Recording Time",
                        value: formattedTotalTime,
                        subtitle: "total",
                        icon: "waveform",
                        color: .red
                    )
                }
                .padding(.horizontal)

                if !recentMeetings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Recent Meetings", systemImage: "clock")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(recentMeetings) { meeting in
                            RecentMeetingCard(meeting: meeting)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onMeetingSelected(meeting)
                                }
                        }
                    }
                }

                if !pendingActions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Pending Action Items", systemImage: "checkmark.circle")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(pendingActions.prefix(5)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "circle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                VStack(alignment: .leading) {
                                    Text(item.text)
                                        .font(.body)
                                    if let assignee = item.assignee {
                                        Text(assignee)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Dashboard")
    }

    private var recentMeetings: [Meeting] {
        Array(allMeetings.sorted { $0.date > $1.date }.prefix(5))
    }

    private var formattedTotalTime: String {
        let hours = Int(totalRecordingTime) / 3600
        let minutes = (Int(totalRecordingTime) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer()
            }
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

struct RecentMeetingCard: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(meeting.status == .recording ? .red : .blue)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .fontWeight(.medium)
                Text(meeting.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(meeting.formattedDuration)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.1), in: Capsule())

            if meeting.pendingActionCount > 0 {
                Text("\(meeting.pendingActionCount) actions")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
