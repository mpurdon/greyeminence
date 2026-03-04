import SwiftUI

struct AISummarySection: View {
    let summary: String
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label {
                Text("Summary")
            } icon: {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
    }
}
