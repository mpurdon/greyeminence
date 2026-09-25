import AppKit
import SwiftUI

/// One unbreakable piece of a laid-out report: a section heading with its
/// first item, a criterion row, a decision card. The screen stacks them; the
/// PDF exporter paginates them, breaking only between blocks — which is how
/// the PDF looks exactly like the app without a card ever being cut in half.
struct RefinementBlock: Identifiable {
    let id: Int
    let spacingBefore: CGFloat
    let view: AnyView
    /// Start a fresh PDF page for this block, whatever room is left.
    var startsNewPage = false
}

@MainActor
enum RefinementReportLayout {
    nonisolated static let sectionSpacing: CGFloat = 24
    nonisolated static let itemSpacing: CGFloat = 10

    /// How the on-screen rationale links items to the evidence panel. Nil
    /// for the PDF, which prints each item's evidence beneath it instead.
    struct Citations {
        let index: RefinementEvidenceIndex
        let selected: Int?
        let onSelect: @MainActor (Int) -> Void

        func chips(_ ref: RefinementItemRef) -> RefinementCitationChips? {
            let numbers = index.numbers(for: ref)
            guard !numbers.isEmpty else { return nil }
            return RefinementCitationChips(numbers: numbers, selected: selected, onSelect: onSelect)
        }
    }

    /// Sections 1–7. The spec (section 8) is laid out separately — its own
    /// tab on screen, the last pages of the PDF.
    /// `leadingSpacing` separates the first section from whatever precedes
    /// it — nothing on screen, the title block in the PDF.
    static func sectionBlocks(_ content: RefinementReportContent, citations: Citations? = nil, leadingSpacing: CGFloat = 0) -> [RefinementBlock] {
        var builder = BlockBuilder(leadingSpacing: leadingSpacing)
        let inline = citations == nil

        builder.section("Intent", systemImage: "scope", items: [
            AnyView(
                Text(content.intent.nonEmpty ?? "Not identified.")
                    .fixedSize(horizontal: false, vertical: true)
            ),
        ])
        builder.section("Acceptance Criteria", systemImage: "checkmark.seal", count: content.acceptanceCriteria.count,
                        items: content.acceptanceCriteria.enumerated().map { i, item in
                            AnyView(RefinementCriterionRow(criterion: item, showsEvidence: inline, chips: citations?.chips(.criterion(i))))
                        })
        builder.section("Decisions", systemImage: "arrow.triangle.branch", count: content.decisions.count,
                        items: content.decisions.enumerated().map { i, item in
                            AnyView(RefinementDecisionCard(decision: item, chips: citations?.chips(.decision(i))))
                        })
        builder.section("Rejected Approaches", systemImage: "xmark.circle", count: content.rejectedApproaches.count,
                        items: content.rejectedApproaches.enumerated().map { i, item in
                            AnyView(RefinementBulletRow(systemImage: "xmark", tint: .red, text: item.approach,
                                                        caption: item.reason?.nonEmpty.map { "Why: \($0)" },
                                                        chips: citations?.chips(.rejected(i))))
                        })
        builder.section("Constraints Discovered", systemImage: "lock", count: content.constraints.count,
                        items: content.constraints.enumerated().map { i, item in
                            AnyView(RefinementBulletRow(systemImage: "lock.fill", tint: .brown, text: item.text,
                                                        caption: item.source?.nonEmpty,
                                                        chips: citations?.chips(.constraint(i))))
                        })
        builder.section("For the Implementer and Reviewer", systemImage: "eye", count: content.reviewerNotes.count,
                        items: content.reviewerNotes.enumerated().map { i, note in
                            AnyView(RefinementBulletRow(systemImage: "lightbulb.fill", tint: .yellow, text: note, caption: nil,
                                                        chips: citations?.chips(.note(i))))
                        })
        builder.section("Open Questions", systemImage: "questionmark.bubble", count: content.openQuestions.count,
                        items: content.openQuestions.enumerated().map { i, item in
                            AnyView(RefinementBulletRow(systemImage: "questionmark", tint: .orange, text: item.question,
                                                        caption: item.owner?.nonEmpty.map { "Owner: \($0)" },
                                                        chips: citations?.chips(.question(i))))
                        })
        return builder.blocks
    }

    /// "Generated Sep 23, 2026 at 4:12 PM · Claude Sonnet" — under the
    /// title on screen and in the PDF.
    static func generatedLine(_ report: RefinementReport) -> String {
        "Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(RefinementReportService.modelLabel(report.modelIdentifier))"
    }

    /// The report's title block, for the PDF — the app shows the same facts
    /// in its header bar.
    static func titleBlock(feature: String, meetingTitle: String, date: Date, duration: String, kind: String, generated: String) -> RefinementBlock {
        RefinementBlock(id: -1, spacingBefore: 0, view: AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Label(kind.uppercased(), systemImage: RefinementStyle.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RefinementStyle.tint)
                Text(feature)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(meetingTitle) · \(date.formatted(date: .abbreviated, time: .shortened)) · \(duration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(generated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Divider().padding(.top, 8)
            }
        ))
    }
}

/// Accumulates blocks, gluing each section heading to its first item so a
/// heading never ends a page on its own.
private struct BlockBuilder {
    let leadingSpacing: CGFloat
    var blocks: [RefinementBlock] = []

    mutating func section(_ title: String, systemImage: String, count: Int? = nil, items: [AnyView]) {
        let header = RefinementSectionHeader(title: title, systemImage: systemImage, count: count)
        let first = items.first ?? AnyView(Text("None identified.").foregroundStyle(.tertiary))
        append(blocks.isEmpty ? leadingSpacing : RefinementReportLayout.sectionSpacing, AnyView(
            VStack(alignment: .leading, spacing: 10) {
                header
                first
            }
        ))
        for item in items.dropFirst() {
            append(RefinementReportLayout.itemSpacing, item)
        }
    }

    private mutating func append(_ spacing: CGFloat, _ view: AnyView) {
        blocks.append(RefinementBlock(
            id: blocks.count,
            spacingBefore: spacing,
            view: AnyView(view.frame(maxWidth: .infinity, alignment: .leading))
        ))
    }
}

/// The feature's identity across the app: sidebar, list, headers, PDF.
enum RefinementStyle {
    static let symbol = "compass.drawing"
    static let tint = Color.teal
}

// MARK: - On screen

/// The rationale tab: sections 1–7 with citation chips that drive the
/// evidence panel.
struct RefinementRationaleView: View {
    let content: RefinementReportContent
    let citations: RefinementReportLayout.Citations

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RefinementReportLayout.sectionBlocks(content, citations: citations)) { block in
                block.view.padding(.top, block.spacingBefore)
            }
        }
        .textSelection(.enabled)
    }
}

/// Ask-style numbered citation chips. The selected one is filled.
struct RefinementCitationChips: View {
    let numbers: [Int]
    let selected: Int?
    let onSelect: @MainActor (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(numbers, id: \.self) { number in
                let isSelected = number == selected
                Button {
                    onSelect(number)
                } label: {
                    Text("\(number)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        .frame(minWidth: 18, minHeight: 16)
                        .padding(.horizontal, 2)
                        .background(
                            isSelected ? Color.accentColor : Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
                .help("Show the transcript passage behind this")
            }
        }
        .fixedSize()
    }
}

// MARK: - Components

struct RefinementSectionHeader: View {
    let title: String
    let systemImage: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct RefinementBasisBadge: View {
    let basis: RefinementReportContent.Basis
    var confidence: RefinementReportContent.Confidence?

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    private var label: String {
        var text = basis.rawValue.uppercased()
        if basis == .inferred, let confidence { text += " · \(confidence.rawValue.uppercased())" }
        return text
    }

    private var tint: Color {
        switch basis {
        case .explicit: .blue
        case .emergent: .purple
        case .inferred: .orange
        }
    }
}

struct RefinementCriterionRow: View {
    let criterion: RefinementReportContent.Criterion
    var showsEvidence = true
    var chips: RefinementCitationChips?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RefinementBasisBadge(basis: criterion.basis, confidence: criterion.confidence)
                .frame(minWidth: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(criterion.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let chips { chips.padding(.top, 2) }
                if showsEvidence, let evidence = criterion.evidence?.nonEmpty {
                    Text(evidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct RefinementDecisionCard: View {
    let decision: RefinementReportContent.Decision
    var chips: RefinementCitationChips?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(decision.decision)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let category = decision.category?.nonEmpty {
                    Text(category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                }
                RefinementBasisBadge(basis: decision.basis == .inferred ? .inferred : .explicit)
            }
            // Fixed label column rather than a Grid: a Grid sized its value
            // column to the text's ideal width, and measured shorter than it
            // drew, so exported cards overlapped.
            VStack(alignment: .leading, spacing: 4) {
                row("Why", decision.reason?.nonEmpty ?? "Not stated in the meeting")
                row("Alternatives", decision.alternatives?.nonEmpty ?? "None discussed")
                if let effect = decision.effect?.nonEmpty { row("Effect", effect) }
            }
            .font(.callout)
            if let chips {
                HStack(spacing: 10) {
                    Text("Evidence")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                    chips
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RefinementBulletRow: View {
    let systemImage: String
    let tint: Color
    let text: String
    let caption: String?
    var chips: RefinementCitationChips?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let chips { chips.padding(.top, 2) }
            }
        }
    }
}

/// Section 8, set apart — the Effective Spec tab, and the PDF's last pages.
/// `parts` lets the PDF exporter split a spec too tall for one page into
/// consecutive cards; on screen it is always whole.
struct RefinementSpecCard: View {
    enum Part: Hashable, CaseIterable {
        case intent
        case list(RefinementReportContent.Spec.List)

        static var allCases: [Part] { [.intent] + RefinementReportContent.Spec.List.allCases.map(Part.list) }
    }

    let spec: RefinementReportContent.Spec
    var showsCopy = false
    var parts: [Part] = Part.allCases
    var showsTitle = true

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                HStack {
                    Label("Effective Spec", systemImage: "doc.text")
                        .font(.headline)
                    Spacer()
                    if showsCopy {
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(RefinementReportMarkdown.spec(spec), forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                }
            }
            ForEach(parts, id: \.self) { part in
                switch part {
                case .intent:
                    Text(spec.intent.nonEmpty ?? "No intent stated.")
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let list): self.list(list.title, spec.items(list))
                }
            }
        }
        .textSelection(.enabled)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RefinementStyle.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RefinementStyle.tint.opacity(0.35)))
    }

    private func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None.").foregroundStyle(.tertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
