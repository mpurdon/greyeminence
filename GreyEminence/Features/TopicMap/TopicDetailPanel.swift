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
                        HStack(spacing: 6) {
                            Menu {
                                TopicCatalogMenuItems(topic: node.label, aliases: node.aliases)
                            } label: {
                                Label(node.kind?.singular ?? "Uncategorized", systemImage: node.kind?.systemImage ?? "questionmark.circle")
                                    .foregroundStyle(node.kind?.tint ?? .secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            Text("· \(node.meetingCount) meeting\(node.meetingCount == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        if !node.aliases.isEmpty {
                            Text("Also: \(node.aliases.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
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
                                        .fill(.primary.opacity(0.3))
                                        .frame(width: 5, height: 5)
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

                    if !viewModel.selectedNeighbours.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connected topics")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            ForEach(viewModel.selectedNeighbours) { neighbour in
                                Button {
                                    viewModel.setSelectedTopic(neighbour.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(neighbour.label)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(neighbour.weight)")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text("shared")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }
}
