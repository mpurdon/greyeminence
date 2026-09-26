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
    ///
    /// `review` is applied either way: your wording, priorities, notes and
    /// answers, your added items. With `actions` (on screen) every item has
    /// its review controls and left-out items stay, dimmed; without (the
    /// PDF) left-out items are gone.
    static func sectionBlocks(
        _ content: RefinementReportContent,
        citations: Citations? = nil,
        review: RefinementReview? = nil,
        actions: RefinementReviewActions? = nil,
        leadingSpacing: CGFloat = 0
    ) -> [RefinementBlock] {
        var builder = BlockBuilder(leadingSpacing: leadingSpacing)
        let inline = citations == nil
        let review = review ?? RefinementReview()

        /// One model item, wrapped with its review; nil when it's left out
        /// of a PDF.
        func item(_ ref: RefinementItemRef, _ section: RefinementReviewSection, _ original: String, _ row: (String?) -> AnyView) -> AnyView? {
            let r = review.item(ref)
            if actions == nil, r.isLeftOut { return nil }
            return AnyView(RefinementReviewedItem(
                target: .item(ref), section: section, text: original, review: r, actions: actions, row: row(r.editedText?.nonEmpty)
            ))
        }
        /// Your own items for a section, then the control to add another.
        func extras(_ section: RefinementReviewSection, _ row: @escaping (String) -> AnyView) -> [AnyView] {
            var views = review.added
                .filter { $0.section == section && !(actions == nil && $0.review.isLeftOut) }
                .map { added in
                    AnyView(RefinementReviewedItem(
                        target: .added(added.id), section: section, text: added.text, review: added.review, actions: actions, row: row(added.text)
                    ))
                }
            if let actions { views.append(AnyView(RefinementAddItemButton(section: section, actions: actions))) }
            return views
        }
        func count(_ n: Int, _ section: RefinementReviewSection) -> Int {
            n + review.added.filter { $0.section == section }.count
        }

        builder.section("Intent", systemImage: "scope", items: [
            AnyView(RefinementReviewedItem(
                target: .intent, section: nil, text: content.intent, review: RefinementItemReview(editedText: review.intent), actions: actions,
                row: AnyView(Text(review.intent?.nonEmpty ?? content.intent.nonEmpty ?? "Not identified.")
                    .fixedSize(horizontal: false, vertical: true))
            )),
        ])
        /// On screen, criteria and constraints are sorted on a board; in
        /// the PDF they're listed with their priority chips.
        func board(_ section: RefinementReviewSection, _ entries: [RefinementBoardEntry], _ actions: RefinementReviewActions) -> [AnyView] {
            [AnyView(RefinementPriorityBoard(section: section, entries: entries, actions: actions))]
        }
        func addedEntries(_ section: RefinementReviewSection, _ row: (String) -> AnyView) -> [RefinementBoardEntry] {
            review.added.filter { $0.section == section }.map {
                RefinementBoardEntry(target: .added($0.id), text: $0.text, review: $0.review, row: row($0.text))
            }
        }

        let criterionRow = { (i: Int, criterion: RefinementReportContent.Criterion, edited: String?) -> AnyView in
            var shown = criterion
            if let edited { shown.text = edited }
            return AnyView(RefinementCriterionRow(criterion: shown, showsEvidence: inline, chips: citations?.chips(.criterion(i))))
        }
        let addedCriterionRow = { (text: String) -> AnyView in
            AnyView(RefinementCriterionRow(criterion: .init(text: text, basis: .added), showsEvidence: false))
        }
        builder.section("Acceptance Criteria", systemImage: "checkmark.seal", count: count(content.acceptanceCriteria.count, .criteria),
                        items: actions.map { actions in
                            board(.criteria, content.acceptanceCriteria.enumerated().map { i, criterion in
                                let r = review.item(.criterion(i))
                                return RefinementBoardEntry(target: .item(.criterion(i)), text: criterion.text, review: r,
                                                            row: criterionRow(i, criterion, r.editedText?.nonEmpty))
                            } + addedEntries(.criteria, addedCriterionRow), actions)
                        } ?? content.acceptanceCriteria.enumerated().compactMap { i, criterion in
                            item(.criterion(i), .criteria, criterion.text) { criterionRow(i, criterion, $0) }
                        } + extras(.criteria, addedCriterionRow))
        builder.section("Decisions", systemImage: "arrow.triangle.branch", count: count(content.decisions.count, .decisions),
                        items: content.decisions.enumerated().compactMap { i, decision in
                            item(.decision(i), .decisions, decision.decision) { edited in
                                var shown = decision
                                if let edited { shown.decision = edited }
                                return AnyView(RefinementDecisionCard(decision: shown, chips: citations?.chips(.decision(i))))
                            }
                        } + extras(.decisions) { text in
                            AnyView(RefinementBulletRow(systemImage: "arrow.triangle.branch", tint: .accentColor, text: text, caption: "Added in review"))
                        })
        builder.section("Rejected Approaches", systemImage: "xmark.circle", count: count(content.rejectedApproaches.count, .rejected),
                        items: content.rejectedApproaches.enumerated().compactMap { i, rejected in
                            item(.rejected(i), .rejected, rejected.approach) { edited in
                                AnyView(RefinementBulletRow(systemImage: "xmark", tint: .red, text: edited ?? rejected.approach,
                                                            caption: rejected.reason?.nonEmpty.map { "Why: \($0)" },
                                                            chips: citations?.chips(.rejected(i))))
                            }
                        } + extras(.rejected) { text in
                            AnyView(RefinementBulletRow(systemImage: "xmark", tint: .red, text: text, caption: "Added in review"))
                        })
        let constraintRow = { (i: Int, constraint: RefinementReportContent.Constraint, edited: String?) -> AnyView in
            AnyView(RefinementBulletRow(systemImage: "lock.fill", tint: .brown, text: edited ?? constraint.text,
                                        caption: constraint.source?.nonEmpty, chips: citations?.chips(.constraint(i))))
        }
        let addedConstraintRow = { (text: String) -> AnyView in
            AnyView(RefinementBulletRow(systemImage: "lock.fill", tint: .brown, text: text, caption: "Added in review"))
        }
        builder.section("Constraints Discovered", systemImage: "lock", count: count(content.constraints.count, .constraints),
                        items: actions.map { actions in
                            board(.constraints, content.constraints.enumerated().map { i, constraint in
                                let r = review.item(.constraint(i))
                                return RefinementBoardEntry(target: .item(.constraint(i)), text: constraint.text, review: r,
                                                            row: constraintRow(i, constraint, r.editedText?.nonEmpty))
                            } + addedEntries(.constraints, addedConstraintRow), actions)
                        } ?? content.constraints.enumerated().compactMap { i, constraint in
                            item(.constraint(i), .constraints, constraint.text) { constraintRow(i, constraint, $0) }
                        } + extras(.constraints, addedConstraintRow))
        builder.section("For the Implementer and Reviewer", systemImage: "eye", count: count(content.reviewerNotes.count, .notes),
                        items: content.reviewerNotes.enumerated().compactMap { i, note in
                            item(.note(i), .notes, note) { edited in
                                AnyView(RefinementBulletRow(systemImage: "lightbulb.fill", tint: .yellow, text: edited ?? note, caption: nil,
                                                            chips: citations?.chips(.note(i))))
                            }
                        } + extras(.notes) { text in
                            AnyView(RefinementBulletRow(systemImage: "lightbulb.fill", tint: .yellow, text: text, caption: "Added in review"))
                        })
        builder.section("Open Questions", systemImage: "questionmark.bubble", count: count(content.openQuestions.count, .questions),
                        items: content.openQuestions.enumerated().compactMap { i, question in
                            item(.question(i), .questions, question.question) { edited in
                                AnyView(RefinementBulletRow(systemImage: "questionmark", tint: .orange, text: edited ?? question.question,
                                                            caption: question.owner?.nonEmpty.map { "Owner: \($0)" },
                                                            chips: citations?.chips(.question(i))))
                            }
                        } + extras(.questions) { text in
                            AnyView(RefinementBulletRow(systemImage: "questionmark", tint: .orange, text: text, caption: "Added in review"))
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
    var review: RefinementReview?
    var actions: RefinementReviewActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RefinementReportLayout.sectionBlocks(content, citations: citations, review: review, actions: actions)) { block in
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
        case .added: .green
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
