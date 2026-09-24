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
/// in a loop.
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
    /// interview, with a summary to judge from, and either never assessed
    /// or listed from before a meeting could hold several features.
    static func needsAssessment(_ meeting: Meeting) -> Bool {
        guard meeting.status == .completed,
              !meeting.isInterviewMeeting,
              !(meeting.latestInsight?.summary.isEmpty ?? true) else { return false }
        let neverAssessed = meeting.refinementLikelihood == nil && meeting.refinementOverride == nil
        let singleFeatureEra = meeting.isRefinementCandidate && meeting.refinementFeatures.isEmpty
        return neverAssessed || singleFeatureEra
    }

    func runIfNeeded(in context: ModelContext) {
        guard !isRunning, !ranThisLaunch else { return }
        let pending = ((try? context.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter(Self.needsAssessment)
            .sorted { $0.date > $1.date }
        guard !pending.isEmpty else { return }

        ranThisLaunch = true
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
                        // Still listed but no names came back: record the one
                        // it had, so the next launch doesn't ask again.
                        if meeting.isRefinementCandidate && meeting.refinementFeatures.isEmpty {
                            meeting.refinementFeatures = [meeting.refinementFeature ?? meeting.title]
                        }
                        if meeting.isRefinementCandidate { flagged += 1 }
                    }
                    PersistenceGate.save(context, site: "RefinementBackfill.batch")
                    checked += batch.count
                }
                LogManager.send("Refinement backfill: done, \(flagged) likely refinement(s)", category: .ai)
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
