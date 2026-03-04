import SwiftUI

struct FollowUpQuestionsSection: View {
    let questions: [String]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
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
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label {
                Text("Follow-up Questions")
            } icon: {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
    }
}
