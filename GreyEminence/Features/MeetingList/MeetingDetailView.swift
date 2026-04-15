import SwiftUI
import SwiftData

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    var onSplitMeeting: ((Meeting) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            MeetingHeaderBar(meeting: meeting)
            Divider()

            if meeting.seriesID != nil, let seriesTitle = meeting.seriesTitle {
                SeriesSectionView(meeting: meeting, seriesTitle: seriesTitle)
                    .padding(.horizontal)
                Divider()
            }

            TranscriptPanelView(meeting: meeting, onSplitMeeting: onSplitMeeting)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SeriesSectionView: View {
    let meeting: Meeting
    let seriesTitle: String

    @Query private var allMeetings: [Meeting]

    private var seriesMeetings: [Meeting] {
        guard let seriesID = meeting.seriesID else { return [] }
        return allMeetings
            .filter { $0.seriesID == seriesID && $0.id != meeting.id }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        if !seriesMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Series: \(seriesTitle)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))

                ForEach(seriesMeetings.prefix(5)) { m in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(m.title)
                            .font(.caption)
                        Spacer()
                        Text(m.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
