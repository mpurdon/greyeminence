import SwiftUI

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
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
                    Text(meeting.date, style: .time)
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
