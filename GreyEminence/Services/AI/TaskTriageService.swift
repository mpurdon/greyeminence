import Foundation
import SwiftData

/// Opt-in switch and throttle for the automatic task tidy-up pass. Plain
/// UserDefaults so the settings toggle can bind through `@AppStorage`.
enum TaskTriageSettings {
    static let enabledKey = "aiTaskTriageEnabled"
    static let lastRunKey = "aiTaskTriageLastRunAt"
    static let lastResultKey = "aiTaskTriageLastResult"

    /// The automatic pass runs at most once a day — same cadence as startup
    /// maintenance, and one call a day is the cost ceiling the toggle
    /// promises.
    static let autoInterval: TimeInterval = 24 * 60 * 60

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var lastRunAt: Date? {
        UserDefaults.standard.object(forKey: lastRunKey) as? Date
    }

    static var lastResult: String? {
        UserDefaults.standard.string(forKey: lastResultKey)
    }

    static func recordRun(_ summary: String, at date: Date = .now) {
        UserDefaults.standard.set(date, forKey: lastRunKey)
        UserDefaults.standard.set(summary, forKey: lastResultKey)
    }

    /// Whether the launch-time pass should spend a call: enabled, not run in
    /// the last day, and there is at least one open task no pass has seen.
    static func isAutoRunDue(hasUntriagedItems: Bool, now: Date = .now) -> Bool {
        guard isEnabled, hasUntriagedItems else { return false }
        guard let last = lastRunAt else { return true }
        return now.timeIntervalSince(last) >= autoInterval
    }
}

enum TaskTriageError: LocalizedError {
    case noAIClient
    case unparseableResponse

    var errorDescription: String? {
        switch self {
        case .noAIClient:
            "No AI provider is configured. Add an API key or AWS profile in Settings → AI."
        case .unparseableResponse:
            "The AI response could not be read."
        }
    }
}

/// One AI pass over the open task list: rate each task's importance, fold
/// duplicates into their canonical item, and drop items that were never
/// tasks. Decisions are applied immediately, but nothing is deleted: a
/// removed or merged item is marked Won't Do with a note saying why, so it
/// sits in the Won't Do section and can be restored. Each one is also
/// logged to the activity log.
///
/// Pure pieces (rendering the prompt, parsing the response, resolving the
/// decisions into a plan) are static and unit-tested without SwiftData.
@MainActor
final class TaskTriageService {
    /// Cap on open tasks sent in one pass. Decisions are ~25 output tokens
    /// each, so 200 fits comfortably inside the default answer budget.
    static let maxItems = 200
    /// Completed tasks are sent as reference only, so an open task that
    /// repeats something already done can be closed rather than kept.
    static let completedReferenceDays = 14
    static let completedReferenceLimit = 40
    /// A pass that wants to drop more than this share of the list is more
    /// likely a bad response than a bad list. Priorities still apply; the
    /// dismissals are skipped and the summary says so.
    nonisolated static let maxDeletionShare = 0.6

    struct Report: Equatable, Sendable {
        var evaluated = 0
        var high = 0
        var medium = 0
        var low = 0
        var merged = 0
        var closed = 0
        var removed = 0
        /// Dismissals the safety cap held back.
        var deletionsHeld = 0
        var skipped = false

        var summary: String {
            if skipped { return "No open tasks to tidy." }
            var parts = ["\(evaluated) task\(evaluated == 1 ? "" : "s") rated (\(high) high, \(medium) medium, \(low) low)"]
            if merged > 0 { parts.append("\(merged) duplicate\(merged == 1 ? "" : "s") merged") }
            if closed > 0 { parts.append("\(closed) already done") }
            if removed > 0 { parts.append("\(removed) marked Won't Do") }
            if deletionsHeld > 0 { parts.append("\(deletionsHeld) dismissal\(deletionsHeld == 1 ? "" : "s") held back for review") }
            return parts.joined(separator: ", ")
        }
    }

    /// Snapshot of one task as the model sees it. Value type so rendering
    /// and tests never touch a model object.
    struct Candidate: Equatable, Sendable {
        let text: String
        let assignee: String?
        let meetingTitle: String?
        let meetingDate: Date?
        let createdAt: Date

        init(text: String, assignee: String? = nil, meetingTitle: String? = nil, meetingDate: Date? = nil, createdAt: Date) {
            self.text = text
            self.assignee = assignee
            self.meetingTitle = meetingTitle
            self.meetingDate = meetingDate
            self.createdAt = createdAt
        }

        init(_ item: ActionItem) {
            self.init(
                text: item.text,
                assignee: item.displayAssignee,
                meetingTitle: item.meeting?.title,
                meetingDate: item.meeting?.date,
                createdAt: item.createdAt
            )
        }
    }

    /// What the model said about one open task, by its position in the
    /// list that was sent.
    struct Decision: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            case pending(Int)
            case completed(Int)
        }

        enum Action: Equatable, Sendable {
            case keep(ActionItemPriority)
            case duplicate(of: Target)
            case remove(reason: String)
        }

        let index: Int
        let action: Action
    }

    /// Decisions after validation: every index in range, every duplicate
    /// pointing at something that survives, chains flattened.
    struct Plan: Equatable, Sendable {
        var priorities: [Int: ActionItemPriority] = [:]
        /// Open task → the open task it folds into.
        var merges: [Int: Int] = [:]
        /// Open task → the completed task it was already done as.
        var closures: [Int: Int] = [:]
        var removals: [Int: String] = [:]

        var deletionCount: Int { merges.count + closures.count + removals.count }
    }

    private let client: any AIClient

    init(client: any AIClient) {
        self.client = client
    }

    // MARK: - Entry points

    /// Tidy `pending` in place. `completed` is reference only. Caller picks
    /// the scope (the Tasks view passes whatever its filter shows).
    func triage(pending: [ActionItem], completed: [ActionItem], in context: ModelContext) async throws -> Report {
        guard !pending.isEmpty else { return Report(skipped: true) }

        // Newest first, so a list past the cap drops its oldest tail — the
        // part the stalled section is already nagging about.
        let open = Array(pending.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maxItems))
        let reference = Array(completed.sorted { $0.createdAt > $1.createdAt }.prefix(Self.completedReferenceLimit))
        let now = Date.now

        let prompt = AIPromptTemplates.taskTriagePrompt(
            today: Self.dateLabel(now),
            pendingTasks: Self.renderPending(open.map(Candidate.init), now: now),
            completedTasks: Self.renderCompleted(reference.map(Candidate.init))
        )

        LogManager.send("Task tidy-up starting (\(open.count) open, \(reference.count) completed for reference)", category: .ai)

        let response = try await AIUsageContext.attribute(.taskTriage) {
            try await AIRetry.run(label: "taskTriage") { [client, prompt] in
                try await withTimeout(seconds: 90) {
                    try await client.sendMessage(
                        system: AIPromptTemplates.taskTriageSystemPrompt,
                        userContent: prompt
                    )
                }
            }
        }

        guard let decisions = Self.parse(response: response) else {
            LogManager.send(
                "Task tidy-up parse failed — raw: " + AIResponseDecoder.failureExcerpt(response),
                category: .ai,
                level: .warning
            )
            throw TaskTriageError.unparseableResponse
        }

        let plan = Self.resolve(decisions, pendingCount: open.count, completedCount: reference.count)
        let report = apply(plan, to: open, completed: reference, in: context, now: now)
        LogManager.send("Task tidy-up complete: \(report.summary)", category: .ai)
        return report
    }

    /// Build a client, gather the reference list, run, and record the
    /// outcome for the settings pane. Shared by the toolbar button, the
    /// settings "Tidy now" button and the launch-time automatic pass.
    static func run(pending: [ActionItem], in context: ModelContext) async throws -> Report {
        guard let client = try await AIClientFactory.makeClient() else {
            throw TaskTriageError.noAIClient
        }
        let cutoff = Date.now.addingTimeInterval(-Double(completedReferenceDays) * 24 * 60 * 60)
        let descriptor = FetchDescriptor<ActionItem>(
            predicate: #Predicate { $0.isCompleted && $0.createdAt >= cutoff }
        )
        let completed = (try? context.fetch(descriptor)) ?? []
        let report = try await TaskTriageService(client: client).triage(pending: pending, completed: completed, in: context)
        TaskTriageSettings.recordRun(report.summary)
        return report
    }

    /// Launch-time pass over every open task. Spends a call only when the
    /// toggle is on, a day has passed, and something new has appeared.
    static func runAutomaticPassIfDue(in context: ModelContext) async {
        let descriptor = FetchDescriptor<ActionItem>(
            predicate: #Predicate { !$0.isCompleted && $0.dismissedAt == nil }
        )
        guard let pending = try? context.fetch(descriptor) else { return }
        let hasUntriaged = pending.contains { $0.lastTriagedAt == nil }
        guard TaskTriageSettings.isAutoRunDue(hasUntriagedItems: hasUntriaged) else { return }
        do {
            let report = try await TransientActivityCoordinator.shared.runAsync("Tidying tasks with AI…") {
                try await run(pending: pending, in: context)
            }
            TransientActivityCoordinator.shared.flash("Tasks tidied: \(report.summary)")
        } catch {
            LogManager.send("Automatic task tidy-up failed: \(error.localizedDescription)", category: .ai, level: .warning)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    private nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated static func dateLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    nonisolated static func renderPending(_ candidates: [Candidate], now: Date) -> String {
        guard !candidates.isEmpty else { return "(none)" }
        return candidates.enumerated().map { index, candidate in
            var fields = ["T\(index + 1)", quote(candidate.text)]
            fields.append("assignee: \(candidate.assignee ?? "unassigned")")
            if let title = candidate.meetingTitle {
                var meeting = "from: \(quote(title))"
                if let date = candidate.meetingDate { meeting += " (\(dateLabel(date)))" }
                fields.append(meeting)
            }
            let days = max(0, Calendar.current.dateComponents([.day], from: candidate.createdAt, to: now).day ?? 0)
            fields.append("age: \(days)d")
            return fields.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    nonisolated static func renderCompleted(_ candidates: [Candidate]) -> String {
        guard !candidates.isEmpty else { return "(none)" }
        return candidates.enumerated().map { index, candidate in
            var fields = ["C\(index + 1)", quote(candidate.text)]
            if let title = candidate.meetingTitle { fields.append("from: \(quote(title))") }
            fields.append("created: \(dateLabel(candidate.createdAt))")
            return fields.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private nonisolated static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'") + "\""
    }

    /// Decisions in response order. Nil when there is no `decisions` array
    /// at all; individual malformed entries are dropped, not fatal.
    nonisolated static func parse(response: String) -> [Decision]? {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let raw = object["decisions"] as? [[String: Any]] else {
            return nil
        }
        return raw.compactMap { entry in
            guard let index = pendingIndex(entry["id"]),
                  let action = (entry["action"] as? String)?.lowercased() else { return nil }
            switch action {
            case "keep":
                let priority = (entry["priority"] as? String)
                    .flatMap { ActionItemPriority(rawValue: $0.lowercased()) } ?? .medium
                return Decision(index: index, action: .keep(priority))
            case "duplicate":
                guard let target = target(entry["of"]) else { return nil }
                return Decision(index: index, action: .duplicate(of: target))
            case "remove":
                let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Decision(index: index, action: .remove(reason: reason))
            default:
                return nil
            }
        }
    }

    private nonisolated static func pendingIndex(_ value: Any?) -> Int? {
        guard case .pending(let index)? = target(value) else { return nil }
        return index
    }

    private nonisolated static func target(_ value: Any?) -> Decision.Target? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces).uppercased(),
              let prefix = string.first,
              let number = Int(string.dropFirst()), number >= 1 else { return nil }
        switch prefix {
        case "T": return .pending(number - 1)
        case "C": return .completed(number - 1)
        default: return nil
        }
    }

    /// Validate decisions against the lists that were sent. Out-of-range
    /// ids, self-duplicates and duplicate chains that end in a removed or
    /// missing item all fall back to "keep, unrated" — the conservative
    /// reading. A later decision for the same id wins.
    nonisolated static func resolve(_ decisions: [Decision], pendingCount: Int, completedCount: Int) -> Plan {
        var byIndex: [Int: Decision.Action] = [:]
        for decision in decisions where (0..<pendingCount).contains(decision.index) {
            byIndex[decision.index] = decision.action
        }

        var plan = Plan()
        for (index, action) in byIndex {
            switch action {
            case .keep(let priority):
                plan.priorities[index] = priority
            case .remove(let reason):
                plan.removals[index] = reason
            case .duplicate(let target):
                switch terminal(of: target, from: index, byIndex: byIndex, pendingCount: pendingCount, completedCount: completedCount) {
                case .pending(let canonical)?:
                    plan.merges[index] = canonical
                case .completed(let done)?:
                    plan.closures[index] = done
                case nil:
                    break
                }
            }
        }
        return plan
    }

    /// Follow a duplicate chain to the item it ultimately folds into. Nil
    /// when the chain is invalid: out of range, self-referential, cyclic, or
    /// ending in an item that is itself removed.
    private nonisolated static func terminal(
        of target: Decision.Target,
        from origin: Int,
        byIndex: [Int: Decision.Action],
        pendingCount: Int,
        completedCount: Int
    ) -> Decision.Target? {
        var current = target
        var visited: Set<Int> = [origin]
        while true {
            switch current {
            case .completed(let index):
                return (0..<completedCount).contains(index) ? current : nil
            case .pending(let index):
                guard (0..<pendingCount).contains(index), visited.insert(index).inserted else { return nil }
                switch byIndex[index] {
                case .remove?:
                    return nil
                case .duplicate(let next)?:
                    current = next
                case .keep?, nil:
                    return current
                }
            }
        }
    }

    // MARK: - Applying

    private func apply(_ plan: Plan, to open: [ActionItem], completed: [ActionItem], in context: ModelContext, now: Date) -> Report {
        var report = Report(evaluated: open.count)
        let deletionsAllowed = plan.deletionCount <= Self.deletionCap(for: open.count)
        if !deletionsAllowed {
            report.deletionsHeld = plan.deletionCount
            LogManager.send(
                "Task tidy-up wanted to dismiss \(plan.deletionCount) of \(open.count) task(s) — over the safety cap, dismissals skipped",
                category: .ai,
                level: .warning
            )
        }

        for item in open {
            item.lastTriagedAt = now
        }
        for (index, priority) in plan.priorities {
            open[index].priority = priority
            switch priority {
            case .high: report.high += 1
            case .medium: report.medium += 1
            case .low: report.low += 1
            }
        }

        guard deletionsAllowed else {
            PersistenceGate.save(context, site: "TaskTriage.priorities")
            return report
        }

        for (index, canonicalIndex) in plan.merges {
            let duplicate = open[index]
            let canonical = open[canonicalIndex]
            Self.carryOver(from: duplicate, to: canonical)
            LogManager.send("Task tidy-up merged \"\(duplicate.text)\" into \"\(canonical.text)\"", category: .ai)
            Self.dismiss(duplicate, note: "Duplicate of \u{201C}\(canonical.text)\u{201D}", at: now)
            report.merged += 1
        }
        for (index, doneIndex) in plan.closures {
            let item = open[index]
            LogManager.send("Task tidy-up closed \"\(item.text)\" — already done as \"\(completed[doneIndex].text)\"", category: .ai)
            item.isCompleted = true
            report.closed += 1
        }
        for (index, reason) in plan.removals {
            let item = open[index]
            LogManager.send("Task tidy-up marked \"\(item.text)\" Won't Do\(reason.isEmpty ? "" : " — \(reason)")", category: .ai)
            Self.dismiss(item, note: reason.isEmpty ? "Not a task" : reason, at: now)
            report.removed += 1
        }

        PersistenceGate.save(context, site: "TaskTriage.apply")
        return report
    }

    /// Dismissals allowed in a pass over `count` items. Small lists get an
    /// absolute floor so a five-item list can still lose three.
    nonisolated static func deletionCap(for count: Int) -> Int {
        max(5, Int((Double(count) * maxDeletionShare).rounded(.down)))
    }

    /// Won't Do rather than delete: the item stays in the Won't Do section
    /// with the note, and restoring it clears both.
    private static func dismiss(_ item: ActionItem, note: String, at date: Date) {
        item.dismissedAt = date
        item.dismissalNote = note
    }

    /// The duplicate may carry detail the canonical item lacks — an owner,
    /// a due date — and that detail should survive the merge.
    private static func carryOver(from duplicate: ActionItem, to canonical: ActionItem) {
        if canonical.assignedContact == nil, let contact = duplicate.assignedContact {
            canonical.assignedContact = contact
        }
        if (canonical.assignee ?? "").isEmpty, let assignee = duplicate.assignee, !assignee.isEmpty {
            canonical.assignee = assignee
        }
        if canonical.dueDate == nil, let due = duplicate.dueDate {
            canonical.dueDate = due
        }
    }
}
