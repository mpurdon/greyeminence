import Foundation
import SwiftData

/// Assesses meetings analysed before the final analysis learned to flag
/// refinements, so the Refinements list covers the whole library and not
/// just meetings recorded from now on.
///
/// Works from each meeting's stored summary and topics — a few hundred
/// tokens — never the transcript, and asks about many meetings per call.
/// Runs when the Refinements view opens, at most once per launch: a meeting
/// the model skips stays unassessed and is retried next launch rather than
/// in a loop. Also re-scores multi-feature meetings once per
/// `rescoreGeneration`, after the feature rules change.
@Observable
@MainActor
final class RefinementBackfill {
    static let shared = RefinementBackfill()

    nonisolated static let batchSize = 20
    /// Enough to tell a design discussion from a status update, short
    /// enough that a batch stays small.
    nonisolated static let summaryCharacterLimit = 1_200

    private(set) var isRunning = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var lastError: String?
    private var ranThisLaunch = false

    private init() {}

    /// A meeting the backfill can and should assess: finished, not an
    /// interview, never assessed, with a summary to judge from.
    static func needsAssessment(_ meeting: Meeting) -> Bool {
        meeting.status == .completed
            && !meeting.isInterviewMeeting
            && meeting.refinementLikelihood == nil
            && meeting.refinementOverride == nil
            && !(meeting.latestInsight?.summary.isEmpty ?? true)
    }

    /// Bump after changing how the prompts split a meeting into features:
    /// the next run re-scores every meeting listed under more than one, so
    /// the list reflects the new rules without waiting for re-analysis.
    /// 1 — a feature's architecture or design pattern is not a second feature.
    nonisolated static let rescoreGeneration = 1
    private static let rescoreKey = "refinementRescoreGeneration"

    /// A meeting whose split into features predates the current rules.
    static func needsRescore(_ meeting: Meeting) -> Bool {
        meeting.status == .completed
            && !meeting.isInterviewMeeting
            && meeting.refinementFeatures.count > 1
            && !(meeting.latestInsight?.summary.isEmpty ?? true)
    }

    func runIfNeeded(in context: ModelContext) {
        guard !isRunning, !ranThisLaunch else { return }
        // Once per launch even when nothing is pending: the scan walks every
        // meeting's insights, too much to repeat on each visit to the view.
        ranThisLaunch = true
        let unassessed = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.refinementLikelihood == nil && $0.refinementOverride == nil }
        )
        var pending = ((try? context.fetch(unassessed)) ?? []).filter(Self.needsAssessment)
        let rescoring = UserDefaults.standard.integer(forKey: Self.rescoreKey) < Self.rescoreGeneration
        if rescoring {
            pending += ((try? context.fetch(FetchDescriptor<Meeting>())) ?? []).filter(Self.needsRescore)
        }
        pending.sort { $0.date > $1.date }
        guard !pending.isEmpty else {
            if rescoring { UserDefaults.standard.set(Self.rescoreGeneration, forKey: Self.rescoreKey) }
            return
        }

        isRunning = true
        checked = 0
        total = pending.count
        lastError = nil

        Task {
            defer { isRunning = false }
            do {
                guard let client = try await AIClientFactory.makeClient() else {
                    lastError = "AI is not configured."
                    return
                }
                LogManager.send("Refinement backfill: assessing \(pending.count) meeting(s)", category: .ai)
                var flagged = 0
                for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
                    let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
                    let signals = try await assess(batch, client: client)
                    for (index, signal) in signals {
                        let meeting = batch[index]
                        meeting.applyRefinementSignal(signal)
                        if meeting.isRefinementCandidate { flagged += 1 }
                    }
                    PersistenceGate.save(context, site: "RefinementBackfill.batch")
                    checked += batch.count
                }
                LogManager.send("Refinement backfill: done, \(flagged) likely refinement(s)", category: .ai)
                // Only once the whole run succeeded; a failure retries next launch.
                if rescoring { UserDefaults.standard.set(Self.rescoreGeneration, forKey: Self.rescoreKey) }
            } catch {
                lastError = error.localizedDescription
                LogManager.send("Refinement backfill failed: \(error.localizedDescription)", category: .ai, level: .warning)
            }
        }
    }

    private func assess(_ batch: [Meeting], client: any AIClient) async throws -> [Int: RefinementSignal] {
        let prompt = AIPromptTemplates.refinementClassifyPrompt(meetings: Self.catalogue(batch.map(Self.entry)))
        let system = AIPromptTemplates.refinementClassifySystemPrompt
        let response = try await AIUsageContext.attribute(.refinementDetection) {
            try await AIRetry.run(label: "refinementBackfill") { [client, system, prompt] in
                try await withTimeout(seconds: 90) {
                    try await client.sendMessage(system: system, userContent: prompt, maxTokens: 4096)
                }
            }
        }
        return Self.parse(response: response, count: batch.count)
    }

    // MARK: - Pure helpers (unit-tested)

    struct Entry: Sendable, Equatable {
        let title: String
        let date: Date
        let topics: [String]
        let summary: String
    }

    static func entry(for meeting: Meeting) -> Entry {
        let insight = meeting.latestInsight
        return Entry(
            title: meeting.title,
            date: meeting.date,
            topics: insight?.topics ?? [],
            summary: flatten(summary: insight?.summary ?? "")
        )
    }

    /// Stored summaries are JSON sections (or a legacy bullet string);
    /// the classifier only needs the words.
    nonisolated static func flatten(summary raw: String) -> String {
        let text: String
        if let sections = SummarySection.parse(raw) {
            text = sections.map { section in
                ([section.title] + section.points.map { "\($0.label): \($0.detail)" }).joined(separator: "; ")
            }.joined(separator: " | ")
        } else {
            text = raw.replacingOccurrences(of: "\n", with: " ")
        }
        guard text.count > summaryCharacterLimit else { return text }
        return String(text.prefix(summaryCharacterLimit)) + "…"
    }

    nonisolated static func catalogue(_ entries: [Entry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return entries.enumerated().map { index, entry in
            var lines = ["M\(index + 1) | \(entry.title) | \(formatter.string(from: entry.date))"]
            if !entry.topics.isEmpty { lines.append("Topics: \(entry.topics.prefix(12).joined(separator: ", "))") }
            lines.append("Summary: \(entry.summary)")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Maps "M3" back to batch index 2. Unknown identifiers and unreadable
    /// entries are dropped; the rest of the batch still counts.
    nonisolated static func parse(response: String, count: Int) -> [Int: RefinementSignal] {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let items = object["meetings"] as? [[String: Any]] else { return [:] }
        var signals: [Int: RefinementSignal] = [:]
        for item in items {
            guard let id = item["id"] as? String,
                  let index = ReportComposerService.index(from: id, prefix: "M"),
                  (1...count).contains(index),
                  let signal = RefinementSignal.parse(item) else { continue }
            signals[index - 1] = signal
        }
        return signals
    }
}
