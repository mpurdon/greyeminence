import SwiftUI

struct TopicDetailPanel: View {
    let viewModel: TopicMapViewModel
    var onMeetingSelected: ((Meeting) -> Void)?

    var body: some View {
        if let node = viewModel.selectedNode {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.label)
                            .font(.title3.weight(.bold))
                        Text("Mentioned in \(node.meetingCount) meeting\(node.meetingCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    Divider()

                    // Meetings
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meetings")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        ForEach(viewModel.selectedMeetings, id: \.id) { meeting in
                            Button {
                                onMeetingSelected?(meeting)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(node.color)
                                        .frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(meeting.title)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(meeting.date, style: .date)
                                            Text(meeting.formattedDuration)
                                        }
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !viewModel.selectedCoTopics.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Related Topics")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            FlowLayout(spacing: 4) {
                                ForEach(viewModel.selectedCoTopics, id: \.self) { topic in
                                    TopicBadge(topic: topic)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
    }
}
