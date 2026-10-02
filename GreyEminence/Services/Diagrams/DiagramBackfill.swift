import Foundation
import SwiftData

/// Looks for flows and timelines in meetings analysed before the final
/// analysis learned to, from their stored summaries — twenty per call, on
/// Haiku. Runs when the Diagrams view opens, at most once per launch; a
/// meeting the model skips stays unassessed and is tried again next time.
@Observable
@MainActor
final class DiagramBackfill {
    static let shared = DiagramBackfill()

    nonisolated static let batchSize = 20

    private(set) var isRunning = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var lastError: String?
    private var ranThisLaunch = false

    private init() {}

    static func needsAssessment(_ meeting: Meeting, index: DiagramIndexStore) -> Bool {
        meeting.status == .completed
            && !meeting.isInterviewMeeting
            && !index.isAssessed(meeting.id)
            && !(meeting.latestInsight?.summary.isEmpty ?? true)
    }

    func runIfNeeded(in context: ModelContext) {
        guard !isRunning, !ranThisLaunch else { return }
        ranThisLaunch = true
        let index = DiagramIndexStore.shared
        let pending = ((try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? [])
            .filter { Self.needsAssessment($0, index: index) }
        guard !pending.isEmpty else { return }

        isRunning = true
        checked = 0
        total = pending.count
        lastError = nil

        Task {
            defer { isRunning = false }
            do {
                guard let client = try await AIClientFactory.makeLightClient() else {
                    lastError = "AI is not configured."
                    return
                }
                LogManager.send("Diagram backfill: assessing \(pending.count) meeting(s)", category: .ai)
                var found = 0
                for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
                    let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
                    let results = try await assess(batch, client: client)
                    let assessments = results.map { (batch[$0.key].id, $0.value) }
                    found += assessments.reduce(0) { $0 + $1.1.count }
                    index.record(assessments)
                    checked += batch.count
                }
                LogManager.send("Diagram backfill: done, \(found) diagram(s) found", category: .ai)
            } catch {
                lastError = error.localizedDescription
                LogManager.send("Diagram backfill failed: \(error.localizedDescription)", category: .ai, level: .warning)
            }
        }
    }

    private func assess(_ batch: [Meeting], client: any AIClient) async throws -> [Int: [DiagramSignal]] {
        let prompt = AIPromptTemplates.diagramClassifyPrompt(meetings: MeetingSummaryCatalogue.catalogue(batch.map(MeetingSummaryCatalogue.entry)))
        let response = try await AILongRequest.send(
            client, system: AIPromptTemplates.diagramClassifySystemPrompt, prompt: prompt, maxTokens: 4096,
            timeoutSeconds: 90, purpose: .diagramDetection, label: "diagramBackfill"
        )
        return Self.parse(response: response, count: batch.count)
    }

    /// Batch position → what to draw ([] for nothing). Meetings the model
    /// skipped are absent, and stay unassessed.
    nonisolated static func parse(response: String, count: Int) -> [Int: [DiagramSignal]] {
        MeetingSummaryCatalogue.parse(response: response, count: count) { DiagramSignal.parseList($0["diagrams"]) ?? [] }
    }
}
