import SwiftUI

/// One chip per topic kind; tapping hides or shows that kind. Shared by the
/// Topic Map and the Refinements list, each with its own stored choice.
/// Hovering anywhere on the chips shows the whole legend at once, rather
/// than a tooltip per chip after the system's delay.
struct TopicKindFilterBar: View {
    /// Hidden kinds, as stored by `TopicKind.raw`.
    @Binding var hiddenRaw: String
    @State private var showsLegend = false

    private var hidden: Set<TopicKind> { TopicKind.set(from: hiddenRaw) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TopicKind.allCases) { kind in
                chip(kind)
            }
        }
        .onHover { showsLegend = $0 }
        // Drawn over whatever is below rather than as a popover: a popover
        // closes on the next click, which would swallow the click meant
        // for a chip. It ignores the mouse, so the chips stay clickable.
        // Callers give the bar a raised zIndex so it draws over later views.
        .overlay(alignment: .topLeading) {
            if showsLegend {
                legend
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .offset(y: 26)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: showsLegend)
    }

    private func chip(_ kind: TopicKind) -> some View {
        let isShown = !hidden.contains(kind)
        return Button {
            var next = hidden
            if isShown { next.insert(kind) } else { next.remove(kind) }
            hiddenRaw = TopicKind.raw(next)
        } label: {
            Label(kind.label, systemImage: kind.systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 10))
                .frame(width: 22, height: 20)
                .foregroundStyle(isShown ? kind.tint : Color.secondary.opacity(0.5))
                .background(
                    isShown ? kind.tint.opacity(0.15) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    if !isShown {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 16, height: 1)
                            .rotationEffect(.degrees(-35))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShown ? "Hide \(kind.label)" : "Show \(kind.label)")
    }

    /// Every kind, in chip order, with whether it's showing.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(TopicKind.allCases) { kind in
                let isShown = !hidden.contains(kind)
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(isShown ? kind.tint : Color.secondary.opacity(0.5))
                        .frame(width: 16)
                    Text(kind.label)
                        .foregroundStyle(isShown ? .primary : .secondary)
                    Spacer(minLength: 12)
                    Text(isShown ? "Shown" : "Hidden")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
            Divider()
            Text("Click an icon to show or hide it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 200)
    }
}

/// Category and alias controls for one topic: pick its kind, or stop
/// counting one of its other names under it. `topic` is the canonical name.
struct TopicCatalogMenuItems: View {
    let topic: String
    var aliases: [String] = []
    private var store: TopicCatalogStore { .shared }

    var body: some View {
        let current = store.catalog.kind(for: topic)
        Menu("Category") {
            ForEach(TopicKind.allCases) { kind in
                Button {
                    store.setKind(kind, for: topic)
                } label: {
                    if kind == current {
                        Label(kind.singular, systemImage: "checkmark")
                    } else {
                        Label(kind.singular, systemImage: kind.systemImage)
                    }
                }
            }
        }
        if !aliases.isEmpty {
            Menu("Separate") {
                ForEach(aliases, id: \.self) { alias in
                    Button("“\(alias)” is not “\(topic)”") { store.separate(alias) }
                }
            }
        }
    }
}

extension TopicKind {
    var tint: Color {
        switch self {
        case .person: .pink
        case .organization: .indigo
        case .project: .orange
        case .service: .teal
        case .technology: .blue
        case .concept: .yellow
        case .place: .green
        case .other: .gray
        }
    }
}
