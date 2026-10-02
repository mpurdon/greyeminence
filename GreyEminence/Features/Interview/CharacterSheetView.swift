import SwiftUI

/// D&D-styled candidate dossier panel. Renders the `CharacterSheet` produced
/// by `ResumeAnalyzer` with class header, level, six attribute boxes, and
/// short feat/specialization lists. Used in `CandidateDetailView` below the
/// resume row.
struct CharacterSheetView: View {
    let sheet: CharacterSheet

    /// `Color.mix(with:by:)` is macOS 15+, but we deploy to 14.4. Define
    /// the parchment-on-brown text color literally.
    private static let darkBrown = Color(red: 0.35, green: 0.22, blue: 0.10)

    /// True when the panel shows AI reasoning under the level and each
    /// attribute. Open by default since the reasoning is the main reason
    /// to look at the panel — the compact grid is just the index.
    @State private var showReasoning = true

    private var anyReasoningAvailable: Bool {
        sheet.levelReasoning != nil
            || sheet.attributes.contains { $0.reasoning != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            classHeader
            if showReasoning, let reasoning = sheet.levelReasoning, !reasoning.isEmpty {
                reasoningCallout(reasoning)
            }
            attributesGrid
            if !sheet.specializations.isEmpty {
                specializationsRow
            }
            if !sheet.notableFeats.isEmpty {
                feats
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(parchmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.brown.opacity(0.4), lineWidth: 1)
        )
        // Paper in either appearance: secondary and primary text are read
        // against the parchment, not the window.
        .environment(\.colorScheme, .light)
    }

    // MARK: - Header

    private var classHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sheet.className)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Self.darkBrown)
                if let desc = sheet.classDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            Spacer()
            if anyReasoningAvailable {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showReasoning.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showReasoning ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(showReasoning ? "Hide why" : "Why?")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Self.darkBrown)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.brown.opacity(0.15), in: Capsule())
                    .overlay(
                        Capsule().stroke(Self.darkBrown.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(showReasoning ? "Hide AI reasoning for each value" : "See why the AI picked these values")
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text("LVL \(sheet.level)")
                    .font(.system(size: 16, weight: .heavy, design: .serif))
                    .foregroundStyle(Self.darkBrown)
            }
        }
    }

    /// Italicized callout block used to render level / attribute reasoning
    /// when the user toggles `showReasoning`. Indented and faded so it
    /// reads as commentary rather than primary content.
    private func reasoningCallout(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.system(size: 9))
                .foregroundStyle(Self.darkBrown.opacity(0.6))
                .padding(.top, 2)
            reasoningText(text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.75))
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Render reasoning text as parsed markdown when possible — strips
    /// stray `**` / `*` / backtick markers the AI sometimes adds despite
    /// the prompt asking for plain prose. Falls back to plain text if
    /// AttributedString's markdown parser rejects the input.
    private func reasoningText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }

    // MARK: - Attributes

    /// Deterministic 3×2 grid via stacked HStacks. We had `LazyVGrid` here
    /// originally but it doesn't measure correctly inside a List row on
    /// first render — the panel rendered with broken proportions until
    /// the window was resized or refocused. Two HStacks each containing
    /// three `attributeBox` views (which use `.frame(maxWidth: .infinity)`)
    /// give us the same 3-up layout with eager sizing.
    private var attributesGrid: some View {
        let pairs = stride(from: 0, to: sheet.attributes.count, by: 3).map { start in
            Array(sheet.attributes[start..<min(start + 3, sheet.attributes.count)])
        }
        return VStack(spacing: 8) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { attribute in
                        attributeBox(attribute)
                    }
                    // Pad short rows so a partial row's items still get
                    // the same 1/3 width as a full row's.
                    ForEach(row.count..<3, id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func attributeBox(_ attribute: DnDAttribute) -> some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                Text(attribute.abbreviation)
                    .font(.system(size: 9, weight: .heavy, design: .serif))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Text("\(attribute.value)")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(attributeColor(attribute.value))
                Text(attribute.name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.brown.opacity(0.25), lineWidth: 0.5)
            )
            .help(attributeTooltip(attribute))

            if showReasoning, let reasoning = attribute.reasoning, !reasoning.isEmpty {
                reasoningText(reasoning)
                    .font(.system(size: 9))
                    .foregroundStyle(.primary.opacity(0.75))
                    .italic()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Tooltip combines the static descriptor (what the attribute means)
    /// with the AI's per-candidate reasoning (why this value), so the
    /// hover surface is useful even when the reasoning panel is collapsed.
    private func attributeTooltip(_ attribute: DnDAttribute) -> String {
        if let reasoning = attribute.reasoning, !reasoning.isEmpty {
            return "\(attribute.descriptor)\n\nFor this candidate: \(reasoning)"
        }
        return attribute.descriptor
    }

    /// 8 (low) -> red. 10 (median) -> neutral. 18 (max) -> bright green.
    private func attributeColor(_ value: Int) -> Color {
        switch value {
        case ..<9: .red
        case 9...11: .secondary
        case 12...14: .blue
        case 15...16: .green
        default: Color(red: 0.45, green: 0.7, blue: 0.2)
        }
    }

    // MARK: - Specializations

    private var specializationsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Proficiencies")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.darkBrown)
                .tracking(0.5)
            FlowLayout(spacing: 4) {
                ForEach(sheet.specializations, id: \.self) { spec in
                    Text(spec)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.brown.opacity(0.15), in: Capsule())
                        .foregroundStyle(Self.darkBrown)
                }
            }
        }
    }

    // MARK: - Feats

    private var feats: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notable Feats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.darkBrown)
                .tracking(0.5)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(sheet.notableFeats, id: \.self) { feat in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 9))
                            .foregroundStyle(.brown.opacity(0.6))
                            .padding(.top, 3)
                        Text(feat)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Background

    private var parchmentBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.99, green: 0.96, blue: 0.88),
                Color(red: 0.95, green: 0.91, blue: 0.80)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
