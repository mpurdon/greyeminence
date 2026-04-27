import SwiftUI

struct ActionItemsSection: View {
    let items: [ActionItem]
    var onDelete: ((ActionItem) -> Void)?
    @State private var isExpanded = true

    private var pendingItems: [ActionItem] { items.filter { !$0.isCompleted } }
    private var pendingCount: Int { pendingItems.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("Action Items")
                            .font(.subheadline.weight(.semibold))
                        if pendingCount > 0 {
                            Text("\(pendingCount)")
                                .font(.caption2).fontWeight(.bold)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if pendingCount > 0 {
                    CopyButton(label: "Copy", help: "Copy unresolved action items") {
                        Self.plainText(items: pendingItems)
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        ActionItemRow(item: item, onDelete: onDelete)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private static func plainText(items: [ActionItem]) -> String {
        items.map { item -> String in
            if let who = item.displayAssignee, !who.isEmpty {
                return "- [\(who)] \(item.text)"
            }
            return "- \(item.text)"
        }.joined(separator: "\n")
    }
}

struct LiveActionItemsSection: View {
    let items: [ActionItem]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text("Action Items")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(items.count)")
                        .font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
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
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}
