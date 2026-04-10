import SwiftUI

struct ActionItemsSection: View {
    let items: [ActionItem]
    var onDelete: ((ActionItem) -> Void)?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    ActionItemRow(item: item, onDelete: onDelete)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Label {
                    Text("Action Items")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .font(.subheadline.weight(.semibold))
                Spacer()
                let pending = items.filter { !$0.isCompleted }.count
                if pending > 0 {
                    Text("\(pending)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal)
    }
}

struct LiveActionItemsSection: View {
    let items: [ActionItem]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                                .font(.body)
                            if let assignee = item.displayAssignee {
                                Text(assignee)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Label {
                    Text("Action Items")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(items.count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
    }
}
