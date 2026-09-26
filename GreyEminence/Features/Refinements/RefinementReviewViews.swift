import AppKit
import SwiftUI

/// Which part of the rationale a review control acts on.
enum RefinementReviewTarget: Hashable {
    case intent
    case item(RefinementItemRef)
    case added(UUID)

    /// What a dragged item carries: "item:criterion:3", "added:<uuid>".
    var payload: String {
        switch self {
        case .intent: "intent"
        case .item(let ref): "item:" + ref.key
        case .added(let id): "added:" + id.uuidString
        }
    }

    init?(payload: String) {
        if payload == "intent" { self = .intent; return }
        if payload.hasPrefix("item:"), let ref = RefinementItemRef(key: String(payload.dropFirst(5))) {
            self = .item(ref)
            return
        }
        if payload.hasPrefix("added:"), let id = UUID(uuidString: String(payload.dropFirst(6))) {
            self = .added(id)
            return
        }
        return nil
    }
}

/// Where a criterion or constraint sits on the priority board.
enum RefinementBucket: String, CaseIterable, Identifiable {
    case unsorted, must, should, could, wont, ignore

    var id: String { rawValue }

    /// The boxes, in order; `.unsorted` is the workspace above them.
    static let boxes: [RefinementBucket] = [.must, .should, .could, .wont, .ignore]

    init(_ review: RefinementItemReview) {
        if review.isLeftOut { self = .ignore; return }
        switch review.priority {
        case .must: self = .must
        case .should: self = .should
        case .could: self = .could
        case .wont: self = .wont
        case nil: self = .unsorted
        }
    }

    var label: String {
        switch self {
        case .unsorted: "To sort"
        case .must: "Must"
        case .should: "Should"
        case .could: "Could"
        case .wont: "Won't"
        case .ignore: "Ignore"
        }
    }

    var tint: Color {
        switch self {
        case .unsorted: .secondary
        case .must: .red
        case .should: .orange
        case .could: .blue
        case .wont: .gray
        case .ignore: .secondary
        }
    }

    var help: String {
        switch self {
        case .unsorted: "Not sorted yet"
        case .must: "Required for the feature to be done"
        case .should: "Expected, but the feature could ship without it"
        case .could: "Nice to have"
        case .wont: "Decided against — goes in the spec as a non-goal"
        case .ignore: "Left out of the spec entirely"
        }
    }

    /// Filing an item here.
    func apply(to review: inout RefinementItemReview) {
        review.isLeftOut = self == .ignore
        switch self {
        case .must: review.priority = .must
        case .should: review.priority = .should
        case .could: review.priority = .could
        case .wont: review.priority = .wont
        case .unsorted, .ignore: review.priority = nil
        }
    }
}

/// What review controls can do. Nil where the rationale is only shown (the
/// PDF).
struct RefinementReviewActions {
    let update: @MainActor (RefinementReviewTarget, (inout RefinementItemReview) -> Void) -> Void
    let add: @MainActor (RefinementReviewSection, String) -> Void
    let remove: @MainActor (UUID) -> Void
}

/// One rationale item with its review: a priority chip and a menu of
/// changes beside it, your note and answer under it, dimmed when left out
/// of the spec.
struct RefinementReviewedItem: View {
    let target: RefinementReviewTarget
    /// Nil for the intent.
    let section: RefinementReviewSection?
    /// The item's wording before your review: an edit starts from it.
    let text: String
    let review: RefinementItemReview
    let actions: RefinementReviewActions?
    let row: AnyView

    enum Editor: Identifiable {
        case text, note, resolution
        var id: Self { self }
    }

    @State private var editor: Editor?
    @State private var draft = ""

    private var isQuestion: Bool { section == .questions }
    private var isAdded: Bool { if case .added = target { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isQuestion, review.resolution?.nonEmpty != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Resolved")
                }
                row
                    .opacity(review.isLeftOut ? 0.4 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // On screen the board's boxes show priority; the PDF shows chips.
                if let priority = review.priority, actions == nil {
                    RefinementPriorityChip(priority: priority)
                }
                if let actions {
                    controls(actions)
                }
            }
            if let editor {
                editorView(editor)
            }
            // On the board, the Ignore box says it.
            if review.isLeftOut, section?.hasPriority != true {
                Label("Ignored — not in the spec", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !isAdded, target != .intent, review.editedText?.nonEmpty != nil {
                Label("Reworded in review", systemImage: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let resolution = review.resolution?.nonEmpty, editor != .resolution {
                annotation("Resolved", resolution, systemImage: "checkmark.bubble", tint: .green)
            }
            if let note = review.note?.nonEmpty, editor != .note {
                annotation("Note", note, systemImage: "note.text", tint: .yellow)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(_ actions: RefinementReviewActions) -> some View {
        HStack(spacing: 4) {
            Menu {
                Button(isAdded ? "Edit…" : "Reword…") { open(.text) }
                Button(review.note?.nonEmpty == nil ? "Add Note…" : "Edit Note…") { open(.note) }
                if isQuestion {
                    if review.resolution?.nonEmpty == nil {
                        Button("Resolve…") { open(.resolution) }
                    } else {
                        Button("Edit Answer…") { open(.resolution) }
                        Button("Reopen Question") { actions.update(target) { $0.resolution = nil } }
                    }
                }
                if section?.hasPriority == true {
                    Divider()
                    Menu("Move to") {
                        ForEach(RefinementBucket.allCases) { bucket in
                            Button {
                                actions.update(target) { bucket.apply(to: &$0) }
                            } label: {
                                if RefinementBucket(review) == bucket {
                                    Label(bucket.label, systemImage: "checkmark")
                                } else {
                                    Text(bucket.label)
                                }
                            }
                        }
                    }
                } else if target != .intent {
                    Divider()
                    Button(review.isLeftOut ? "Include in Spec" : "Ignore") {
                        actions.update(target) { $0.isLeftOut.toggle() }
                    }
                }
                if !isAdded, target != .intent, review.editedText?.nonEmpty != nil {
                    Button("Restore Original Wording") { actions.update(target) { $0.editedText = nil } }
                }
                if target == .intent, review.editedText?.nonEmpty != nil {
                    Button("Restore Original Intent") { actions.update(target) { $0.editedText = nil } }
                }
                if case .added(let id) = target {
                    Divider()
                    Button("Remove", role: .destructive) { actions.remove(id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // The card around it shows the drag hand; the menu is a click.
            .hoverCursor(.arrow)
            .help(section?.hasPriority == true ? "Reword, add a note, or move to a priority" : "Reword, add a note, resolve, or ignore")
        }
    }

    private func open(_ kind: Editor) {
        switch kind {
        case .text: draft = review.editedText ?? currentText
        case .note: draft = review.note ?? ""
        case .resolution: draft = review.resolution ?? ""
        }
        editor = kind
    }

    /// The wording on show, to start an edit from.
    private var currentText: String { review.editedText?.nonEmpty ?? text }

    private func editorView(_ kind: Editor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt(kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.callout)
                .frame(minHeight: 54, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel") { editor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(kind) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func prompt(_ kind: Editor) -> String {
        switch kind {
        case .text where isAdded: "Text"
        case .text: "Your wording"
        case .note: "Note — context for whoever writes or checks the spec"
        case .resolution: "Answer — how the question was settled"
        }
    }

    private func save(_ kind: Editor) {
        let value = draft.nonEmpty
        actions?.update(target) { review in
            switch kind {
            // Unchanged wording is not an edit.
            case .text: review.editedText = value == text.nonEmpty ? nil : value
            case .note: review.note = value
            case .resolution: review.resolution = value
            }
        }
        editor = nil
    }

    private func annotation(_ title: String, _ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
            (Text(title + ": ").fontWeight(.semibold) + Text(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct RefinementPriorityChip: View {
    let priority: RefinementPriority

    var body: some View {
        Text(priority.label.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var tint: Color {
        switch priority {
        case .must: .red
        case .should: .orange
        case .could: .blue
        case .wont: .secondary
        }
    }
}

/// "+ Add criterion" at the end of a section, opening a field in place.
struct RefinementAddItemButton: View {
    let section: RefinementReviewSection
    let actions: RefinementReviewActions

    @State private var isAdding = false
    @State private var text = ""

    var body: some View {
        if isAdding {
            HStack(spacing: 6) {
                TextField("New \(section.singular)", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(text.nonEmpty == nil)
                Button("Cancel") { isAdding = false; text = "" }
            }
            .controlSize(.small)
        } else {
            Button {
                isAdding = true
            } label: {
                Label("Add \(section.singular)", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        guard let value = text.nonEmpty else { return }
        actions.add(section, value)
        text = ""
        isAdding = false
    }
}

/// Above the rationale: how far the review has got, and the step that ends
/// it — accepting the rationale, which writes the spec.
struct RefinementReviewBar: View {
    let report: RefinementReport
    let isGeneratingSpec: Bool
    let onAccept: () -> Void
    let onReopen: () -> Void
    let onShowSpec: () -> Void

    var body: some View {
        let progress = (report.review ?? RefinementReview()).progress(of: report.content)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: report.isRationaleAccepted ? "checkmark.circle.fill" : "pencil.and.list.clipboard")
                .font(.title3)
                .foregroundStyle(report.isRationaleAccepted ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(summary(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isGeneratingSpec {
                ProgressView().controlSize(.small)
                Text("Writing the spec…").font(.caption).foregroundStyle(.secondary)
            } else if report.isRationaleAccepted {
                Button("Reopen", action: onReopen)
                    .help("Go back to working on the rationale. The spec is kept, marked out of date.")
                Button("View Spec", action: onShowSpec)
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    FeatureDiscovery.shared.markSeen("rationale-review")
                    onAccept()
                } label: {
                    Label("Accept Rationale", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .newFeatureBadge("rationale-review")
                .help("Accept the rationale as reviewed and write the spec from it")
            }
        }
        .controlSize(.regular)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        guard let accepted = report.review?.acceptedAt else { return "Review the rationale" }
        return "Rationale accepted \(accepted.formatted(date: .abbreviated, time: .shortened))"
    }

    private func summary(_ p: RefinementReview.Progress) -> String {
        guard !report.isRationaleAccepted else {
            return "Editing anything reopens it and marks the spec out of date."
        }
        var parts: [String] = []
        let total = p.prioritized + p.needingPriority
        if total > 0 { parts.append("\(p.prioritized) of \(total) prioritized") }
        if p.openQuestions > 0 { parts.append("\(p.openQuestions) open question\(p.openQuestions == 1 ? "" : "s")") }
        if p.notes > 0 { parts.append("\(p.notes) note\(p.notes == 1 ? "" : "s")") }
        if p.leftOut > 0 { parts.append("\(p.leftOut) left out") }
        let status = parts.isEmpty ? "Nothing reviewed yet." : parts.joined(separator: " · ") + "."
        return status + " Set priorities, reword, add notes and answers with the controls beside each item; accept when it says what was decided."
    }
}

/// The Effective Spec tab: written from the accepted rationale, then
/// verified by you.
struct RefinementSpecPane: View {
    let report: RefinementReport
    let isGenerating: Bool
    let onAccept: () -> Void
    let onRetry: () -> Void
    let onVerify: () -> Void
    let onShowRationale: () -> Void

    private var review: RefinementReview? { report.review }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isGenerating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Writing the spec from your reviewed rationale…")
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else if let spec = review?.spec {
                statusBar
                RefinementSpecCard(spec: spec, showsCopy: true)
                    .opacity(review?.specIsStale == true ? 0.6 : 1)
            } else if report.isRationaleAccepted {
                notice(
                    "The rationale is accepted, but the spec hasn't been written yet.",
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                ) {
                    Button("Write Spec", action: onRetry).buttonStyle(.borderedProminent)
                }
            } else {
                notice(
                    "The spec is written from the rationale once you've reviewed and accepted it — so it carries your priorities, answers and wording, and leaves out what you left out.",
                    systemImage: "lock",
                    tint: .secondary
                ) {
                    Button("Review Rationale", action: onShowRationale)
                    Button("Accept Rationale", action: onAccept).buttonStyle(.borderedProminent)
                }
                if report.content.spec != RefinementReportContent.Spec() {
                    Text("DRAFT FROM THE FIRST PASS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RefinementSpecCard(spec: report.content.spec, showsCopy: true)
                        .opacity(0.6)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if review?.specIsStale == true {
            notice("The rationale has changed since this spec was written.", systemImage: "clock.arrow.circlepath", tint: .orange) {
                if report.isRationaleAccepted {
                    Button("Rewrite Spec", action: onRetry).buttonStyle(.borderedProminent)
                } else {
                    Button("Review Rationale", action: onShowRationale)
                    Button("Accept and Rewrite", action: onAccept).buttonStyle(.borderedProminent)
                }
            }
        } else if let verified = review?.specVerifiedAt {
            notice("Verified \(verified.formatted(date: .abbreviated, time: .shortened)).", systemImage: "checkmark.seal.fill", tint: .green) {
                Button("Rewrite Spec", action: onRetry)
            }
        } else {
            notice("Written from your accepted rationale. Check it says what was decided, then verify it.", systemImage: "checkmark.circle", tint: .accentColor) {
                Button("Rewrite", action: onRetry)
                Button(action: onVerify) {
                    Label("Verify Spec", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func notice<Actions: View>(
        _ text: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Priority board

/// One criterion or constraint on the board.
struct RefinementBoardEntry: Identifiable {
    let target: RefinementReviewTarget
    /// Wording before review, for the reword editor.
    let text: String
    let review: RefinementItemReview
    let row: AnyView

    var id: String { target.payload }
}

/// Acceptance criteria or constraints sorted by dragging: each priority is
/// a box with a count, closed until you want to look inside, and below
/// them unsorted items stay open in To sort — the workspace, which empties
/// as you go. Drop on a box, open or closed, to file an item there.
struct RefinementPriorityBoard: View {
    let section: RefinementReviewSection
    let entries: [RefinementBoardEntry]
    let actions: RefinementReviewActions

    @State private var expanded: Set<RefinementBucket> = []
    @State private var targeted: RefinementBucket?

    var body: some View {
        let grouped = Dictionary(grouping: entries) { RefinementBucket($0.review) }
        // The boxes first — closed, one line each — so the workspace below
        // is where the sorting happens and the counts sit where you look.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RefinementBucket.boxes) { bucket in
                box(bucket, grouped[bucket] ?? [])
            }
            box(.unsorted, grouped[.unsorted] ?? [])
        }
    }

    private func isOpen(_ bucket: RefinementBucket) -> Bool {
        bucket == .unsorted || expanded.contains(bucket)
    }

    private func box(_ bucket: RefinementBucket, _ items: [RefinementBoardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(bucket, count: items.count)
            if isOpen(bucket) {
                if items.isEmpty, bucket == .unsorted {
                    Text(entries.isEmpty ? "Nothing here yet." : "All sorted. Open a box to see what's in it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if items.isEmpty {
                    Text("Drag items here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(items) { entry in
                    RefinementReviewedItem(
                        target: entry.target, section: section, text: entry.text,
                        review: entry.review, actions: actions, row: entry.row
                    )
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.6)))
                    .hoverCursor(.openHand)
                    .draggable(entry.target.payload) {
                        Text(entry.review.editedText?.nonEmpty ?? entry.text)
                            .lineLimit(2)
                            .frame(maxWidth: 320, alignment: .leading)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if bucket == .unsorted {
                    RefinementAddItemButton(section: section, actions: actions)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bucket.tint.opacity(targeted == bucket ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted == bucket ? bucket.tint : bucket.tint.opacity(0.25), lineWidth: targeted == bucket ? 2 : 1)
        )
        .dropDestination(for: String.self) { payloads, _ in
            let targets = payloads.compactMap(RefinementReviewTarget.init(payload:))
            for target in targets {
                actions.update(target) { bucket.apply(to: &$0) }
            }
            return !targets.isEmpty
        } isTargeted: { isOver in
            if isOver { targeted = bucket } else if targeted == bucket { targeted = nil }
        }
    }

    private func header(_ bucket: RefinementBucket, count: Int) -> some View {
        Button {
            guard bucket != .unsorted else { return }
            if expanded.contains(bucket) { expanded.remove(bucket) } else { expanded.insert(bucket) }
        } label: {
            HStack(spacing: 8) {
                if bucket != .unsorted {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen(bucket) ? 90 : 0))
                        .frame(width: 10)
                }
                Text(bucket.label.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(bucket == .unsorted || bucket == .ignore ? Color.secondary : bucket.tint)
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(bucket.tint.opacity(0.15), in: Capsule())
                Text(bucket.help)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cursor

extension View {
    /// Show `cursor` while the pointer is over this view.
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursor(cursor: cursor))
    }
}

/// Pushes the cursor on entry and pops it on exit — and on disappearing,
/// since a card dropped into a closed box vanishes from under the pointer
/// without an exit, which would otherwise leave the hand stuck.
private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !isPushed {
                    cursor.push()
                    isPushed = true
                } else if !inside, isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}
