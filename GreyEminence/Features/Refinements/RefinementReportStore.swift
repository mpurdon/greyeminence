import Foundation
import Observation

/// One entry on the Refinements list: a feature a meeting refined. A meeting
/// that refined three features is three topics, each with its own report
/// and ticket.
struct RefinementTopic: Hashable, Identifiable {
    let meeting: Meeting
    let feature: String
    /// 0-based position in the meeting's features, most time spent first.
    let position: Int
    /// How many features the meeting refined.
    let count: Int

    var id: String { "\(meeting.id.uuidString)|\(RefinementReportShelf.key(for: feature))" }
    var isFirst: Bool { position == 0 }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor
    static func topics(for meeting: Meeting) -> [RefinementTopic] {
        let features = meeting.refinementTopics
        return features.enumerated().map { index, feature in
            RefinementTopic(meeting: meeting, feature: feature, position: index, count: features.count)
        }
    }
}

/// Refinement reports on disk, plus the generations in flight.
///
/// Generation lives here rather than in the detail view so that it keeps
/// going when the user selects another topic, and so list rows can show
/// which topics have a report or one on the way.
@Observable
@MainActor
final class RefinementReportStore {
    static let shared = RefinementReportStore()

    /// Topic IDs being generated.
    private(set) var generating: Set<String> = []
    /// Topic IDs whose spec is being written from the accepted rationale.
    private(set) var generatingSpec: Set<String> = []
    private(set) var errors: [String: String] = [:]

    /// Bumped on every write so views reading through `report(for:)` —
    /// which is backed by an unobserved cache — redraw.
    private(set) var revision = 0

    /// Kept out of observation so a first read from inside a view body is
    /// not a state change during rendering.
    @ObservationIgnored private var shelves: [UUID: RefinementReportShelf] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func report(for topic: RefinementTopic) -> RefinementReport? {
        shelf(topic.meeting.id).report(for: topic.feature, isFirst: topic.isFirst, knownFeatures: topic.meeting.refinementTopics)
    }

    func isGenerating(_ topic: RefinementTopic) -> Bool { generating.contains(topic.id) }

    func status(for topic: RefinementTopic) -> RefinementStatus {
        report(for: topic)?.status ?? .notBuilt
    }

    /// Set by hand, from the report header or a list row. Needs a report:
    /// with none, the topic is simply not built yet.
    func setStatus(_ status: RefinementStatus, for topic: RefinementTopic) {
        guard var report = report(for: topic), report.status != status else { return }
        report.reviewStatus = status
        save(report, for: topic)
    }

    /// Opening a New report puts it In Progress; any other status is left alone.
    func markRead(_ topic: RefinementTopic) {
        if status(for: topic) == .new { setStatus(.inProgress, for: topic) }
    }

    // MARK: - Review

    func isGeneratingSpec(_ topic: RefinementTopic) -> Bool { generatingSpec.contains(topic.id) }

    func editReview(_ topic: RefinementTopic, _ change: (inout RefinementReview) -> Void) {
        guard var report = report(for: topic) else { return }
        let before = report
        report.editReview(change)
        if report != before { save(report, for: topic) }
    }

    /// Accept the rationale and write the spec from it.
    func acceptRationale(_ topic: RefinementTopic) {
        guard var report = report(for: topic) else { return }
        report.acceptRationale()
        save(report, for: topic)
        generateSpec(topic)
    }

    func reopenRationale(_ topic: RefinementTopic) {
        guard var report = report(for: topic) else { return }
        report.reopenRationale()
        save(report, for: topic)
    }

    func verifySpec(_ topic: RefinementTopic) {
        guard var report = report(for: topic) else { return }
        report.verifySpec()
        save(report, for: topic)
    }

    /// Write the spec from the accepted rationale. Also the retry after a
    /// failed attempt.
    func generateSpec(_ topic: RefinementTopic) {
        let key = topic.id
        guard !generatingSpec.contains(key), let report = report(for: topic), report.isRationaleAccepted else { return }
        let meetingID = topic.meeting.id
        let feature = topic.feature
        let rationale = RefinementReportMarkdown.rationale(report.content, review: report.review)
        generatingSpec.insert(key)
        errors[key] = nil

        tasks["spec|" + key] = Task {
            defer {
                generatingSpec.remove(key)
                tasks["spec|" + key] = nil
            }
            do {
                guard let client = try await AIClientFactory.makeClient() else {
                    errors[key] = "AI is not configured. Add an account in Settings → AI."
                    return
                }
                let spec = try await RefinementSpecService(client: client).generate(feature: feature, rationale: rationale, meetingID: meetingID)
                // Written for the rationale as accepted; if it was reopened
                // meanwhile, still keep it — marked out of date by the edit.
                guard var current = self.report(for: topic) else { return }
                current.storeSpec(spec, modelIdentifier: client.modelIdentifier)
                if !current.isRationaleAccepted { current.review?.specIsStale = true }
                save(current, for: topic)
                LogManager.send("Refinement spec generated from the reviewed rationale", category: .ai, meetingID: meetingID)
            } catch {
                guard !Task.isCancelled else { return }
                errors[key] = "Couldn't write the spec: \(error.localizedDescription)"
                LogManager.send("Refinement spec failed: \(error.localizedDescription)", category: .ai, level: .error, meetingID: meetingID)
            }
        }
    }

    func error(for topic: RefinementTopic) -> String? { errors[topic.id] }

    func generate(for topic: RefinementTopic) {
        let key = topic.id
        guard !generating.contains(key) else { return }
        let meetingID = topic.meeting.id
        let input = RefinementReportService.input(for: topic.meeting, feature: topic.feature)
        generating.insert(key)
        errors[key] = nil

        tasks[key] = Task {
            defer {
                generating.remove(key)
                tasks[key] = nil
            }
            do {
                guard let client = try await AIClientFactory.makeClient() else {
                    errors[key] = "AI is not configured. Add an account in Settings → AI."
                    return
                }
                var report = try await RefinementReportService(client: client).generate(input, meetingID: meetingID)
                // A regenerated report is about the same feature; keep the
                // ticket already filed for it rather than inviting a duplicate.
                // New content needs reading again, unless it is already filed.
                report.jiraIssue = self.report(for: topic)?.jiraIssue
                report.reviewStatus = report.jiraIssue == nil ? .new : .filed
                save(report, for: topic)
            } catch {
                guard !Task.isCancelled else { return }
                errors[key] = error.localizedDescription
                LogManager.send("Refinement report failed: \(error.localizedDescription)", category: .ai, level: .error, meetingID: meetingID)
            }
        }
    }

    func cancel(_ topic: RefinementTopic) {
        tasks[topic.id]?.cancel()
    }

    func dismissError(for topic: RefinementTopic) {
        errors[topic.id] = nil
    }

    func attach(_ issue: JiraIssueLink, to topic: RefinementTopic) {
        guard var report = report(for: topic) else { return }
        report.jiraIssue = issue
        report.reviewStatus = .filed
        save(report, for: topic)
    }

    private func shelf(_ meetingID: UUID) -> RefinementReportShelf {
        _ = revision
        if let cached = shelves[meetingID] { return cached }
        let loaded = StorageManager.shared.loadRefinementShelf(for: meetingID)
        shelves[meetingID] = loaded
        return loaded
    }

    private func save(_ report: RefinementReport, for topic: RefinementTopic) {
        var shelf = shelf(topic.meeting.id)
        shelf.store(report, for: topic.feature, isFirst: topic.isFirst)
        StorageManager.shared.saveRefinementShelf(shelf, for: topic.meeting.id)
        shelves[topic.meeting.id] = shelf
        revision += 1
    }
}
