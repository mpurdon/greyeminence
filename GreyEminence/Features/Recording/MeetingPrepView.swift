import SwiftUI

struct MeetingPrepView: View {
    let context: MeetingPrepContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Meeting Prep", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            if !context.unresolvedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unresolved Items")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                    ForEach(context.unresolvedItems.prefix(5)) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .foregroundStyle(item.daysSinceCreated > 14 ? .red : .orange)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.text)
                                    .font(.caption)
                                HStack(spacing: 4) {
                                    if let assignee = item.assignee {
                                        Text(assignee)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(item.daysSinceCreated)d ago")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            if !context.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Questions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)

                    ForEach(context.followUps.prefix(3), id: \.self) { question in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.top, 2)
                            Text(question)
                                .font(.caption)
                        }
                    }
                }
            }

            if !context.previousTopics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous Topics")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 4) {
                        ForEach(context.previousTopics.prefix(8), id: \.self) { topic in
                            Text(topic)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
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

