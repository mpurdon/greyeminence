import SwiftUI

struct FollowUpQuestionsSection: View {
    let questions: [String]
    var onDelete: ((Int) -> Void)?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("Follow-up Questions")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !questions.isEmpty {
                    CopyButton(label: "Copy", help: "Copy all follow-up questions") {
                        questions.enumerated()
                            .map { "\($0.offset + 1). \($0.element)" }
                            .joined(separator: "\n")
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(question)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(question, forType: .string)
                            }
                            if let onDelete {
                                Divider()
                                Button("Delete", role: .destructive) {
                                    onDelete(index)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}
