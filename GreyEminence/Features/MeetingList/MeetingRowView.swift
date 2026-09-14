import SwiftUI

struct MeetingRowView: View {
    let meeting: Meeting

    private var dateLabel: String {
        let calendar = Calendar.current
        let date = meeting.date
        let time = date.formatted(date: .omitted, time: .shortened)

        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return time
        }

        let weekday = date.formatted(.dateTime.weekday(.wide))
        let month = date.formatted(.dateTime.month(.abbreviated))
        let day = calendar.component(.day, from: date)
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        let dayString = ordinal.string(from: NSNumber(value: day)) ?? "\(day)"

        let nowYear = calendar.component(.year, from: .now)
        let dateYear = calendar.component(.year, from: date)
        if dateYear == nowYear {
            return "\(weekday), \(month) \(dayString) · \(time)"
        }
        return "\(weekday), \(month) \(dayString), \(dateYear) · \(time)"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if meeting.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(45))
                            .accessibilityLabel("Pinned")
                    }

                    Text(meeting.title)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if meeting.status == .recording {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                    }
                }

                HStack(spacing: 8) {
                    Text(dateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if meeting.segments.count > 0 {
                        Text("\(meeting.segments.count) segments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(meeting.formattedDuration)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.1), in: Capsule())

                if meeting.pendingActionCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                        Text("\(meeting.pendingActionCount)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
            }

            if let sourceApp = meeting.sourceAppName {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Recorded from \(sourceApp)")
            }

            if meeting.seriesID != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.teal)
                    .help(meeting.seriesTitle ?? "Series")
            }

            if meeting.isExportedToObsidian {
                Image(systemName: "arrow.up.doc")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
        .padding(.vertical, 4)
    }
}
