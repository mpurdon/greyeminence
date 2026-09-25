import XCTest
import SwiftData
@testable import Grey_Eminence

@MainActor
final class RefinementListGroupingTests: XCTestCase {

    /// Built per test rather than in `setUp` — the context is MainActor-bound
    /// and `setUpWithError` is not.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func meeting(
        _ title: String,
        daysAgo: Double,
        features: [String],
        topics: [String] = [],
        in context: ModelContext
    ) -> Meeting {
        let meeting = Meeting(title: title, status: .completed)
        meeting.date = Date(timeIntervalSince1970: 1_790_000_000 - daysAgo * 86_400)
        meeting.refinementFeatures = features
        context.insert(meeting)
        if !topics.isEmpty {
            let insight = MeetingInsight(summary: "s", topics: topics)
            context.insert(insight)
            insight.meeting = meeting
        }
        return meeting
    }

    private func rows(_ meetings: [Meeting]) -> [RefinementTopic] {
        meetings.flatMap(RefinementTopic.topics(for:))
    }

    // MARK: - Status

    func testStatusDefaultsFromTheReport() throws {
        var report = RefinementReport(
            content: RefinementReportContent(intent: "x"),
            generatedAt: .now,
            modelIdentifier: "m",
            promptVersion: "v",
            transcriptFingerprint: "f"
        )
        XCTAssertEqual(report.status, .new, "an unreviewed report is New")
        report.jiraIssue = JiraIssueLink(key: "UP-1", url: URL(string: "https://x.atlassian.net/browse/UP-1")!, createdAt: .now)
        XCTAssertEqual(report.status, .filed, "a report with a ticket is Filed")
        report.reviewStatus = .followUp
        XCTAssertEqual(report.status, .followUp, "a status set by hand wins")
        XCTAssertFalse(RefinementStatus.settable.contains(.notBuilt))
    }

    func testReportsWithoutAStatusAndUnknownStatusesStillDecode() throws {
        let report = RefinementReport(
            content: RefinementReportContent(intent: "x"),
            generatedAt: Date(timeIntervalSince1970: 1),
            modelIdentifier: "m",
            promptVersion: "v",
            transcriptFingerprint: "f"
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertNil(object["reviewStatus"], "0.51.0 wrote no status")
        XCTAssertEqual(try JSONDecoder().decode(RefinementReport.self, from: JSONSerialization.data(withJSONObject: object)).status, .new)

        object["reviewStatus"] = "archivedByAFutureVersion"
        let decoded = try JSONDecoder().decode(RefinementReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.status, .read)
    }

    // MARK: - Grouping

    func testMeetingGroupingKeepsEachCallsFeaturesTogether() throws {
        let context = try makeContext()
        let older = meeting("Grooming", daysAgo: 3, features: ["Export", "Retries"], in: context)
        let newer = meeting("Kickoff", daysAgo: 1, features: ["Intake"], in: context)
        let sections = RefinementListGrouper.sections(rows([newer, older]), by: .meeting, status: { _ in .notBuilt })
        XCTAssertEqual(sections.map(\.title), ["Kickoff", "Grooming"])
        XCTAssertEqual(sections[1].topics.map(\.feature), ["Export", "Retries"])
    }

    func testStatusGroupingPutsWhatNeedsAttentionFirst() throws {
        let context = try makeContext()
        let a = meeting("A", daysAgo: 1, features: ["One", "Two", "Three"], in: context)
        let statuses: [String: RefinementStatus] = ["One": .approved, "Two": .new, "Three": .followUp]
        let sections = RefinementListGrouper.sections(rows([a]), by: .status, status: { statuses[$0.feature]! })
        XCTAssertEqual(sections.map(\.title), ["New", "Follow-up", "Approved"])
    }

    func testTopicGroupingCountsMeetingsLikeTheTopicMap() throws {
        let context = try makeContext()
        let recent = meeting("Recent", daysAgo: 1, features: ["Intake"], topics: ["Lead Service"], in: context)
        let middle = meeting("Middle", daysAgo: 5, features: ["Export"], topics: ["lead service ", "Mongo"], in: context)
        let old = meeting("Old", daysAgo: 9, features: ["Retries"], topics: ["Mongo", "Lead service"], in: context)
        let bare = meeting("Bare", daysAgo: 2, features: ["Misc"], in: context)
        let topics = rows([recent, bare, middle, old])

        let byMentions = RefinementListGrouper.sections(topics, by: .topic, topicOrder: .mentions, status: { _ in .notBuilt })
        XCTAssertEqual(byMentions.map(\.title), ["Lead Service", "Mongo", "No Topics"], "three meetings beat two; case folds together")
        XCTAssertEqual(byMentions[0].topics.map(\.feature), ["Intake", "Export", "Retries"])
        XCTAssertEqual(byMentions[0].subtitle, "3 meetings")
        XCTAssertEqual(byMentions[2].topics.map(\.feature), ["Misc"])

        let mongoOnlyRecent = meeting("Newest", daysAgo: 0, features: ["Index"], topics: ["Mongo"], in: context)
        let byRecent = RefinementListGrouper.sections(rows([mongoOnlyRecent]) + topics, by: .topic, topicOrder: .recent, status: { _ in .notBuilt })
        XCTAssertEqual(byRecent.first?.title, "Mongo", "the most recently discussed topic leads")
    }

    func testTopicGroupingLeavesOutHiddenKindsAndMergesAliases() throws {
        let context = try makeContext()
        let call = meeting("Sync", daysAgo: 1, features: ["Intake"],
                           topics: ["Walter", "Lead Service", "dynamo", "Tj"], in: context)
        let other = meeting("Design", daysAgo: 2, features: ["Export"], topics: ["DynamoDB"], in: context)
        var catalog = TopicCatalog()
        catalog.apply(kind: .person, canonical: "Walter Martens", to: "Walter", version: 1)
        catalog.apply(kind: .technology, canonical: "DynamoDB", to: "dynamo", version: 1)
        catalog.apply(kind: .technology, canonical: nil, to: "DynamoDB", version: 1)
        catalog.apply(kind: .service, canonical: nil, to: "Lead Service", version: 1)
        // "Tj" is unclassified and not a contact, so it stays.
        let resolver = TopicResolver(catalog: catalog, hiddenKinds: [.person])

        let sections = RefinementListGrouper.sections(rows([call, other]), by: .topic, resolver: resolver, status: { _ in .notBuilt })
        XCTAssertEqual(sections.map(\.title), ["DynamoDB", "Lead Service", "Tj"], "dynamo counts as DynamoDB; Walter is hidden")
        XCTAssertEqual(sections[0].subtitle, "2 meetings")
        XCTAssertEqual(sections[0].topicKind, .technology)
    }

    func testUnclassifiedContactNamesCountAsPeople() throws {
        let context = try makeContext()
        let call = meeting("1:1", daysAgo: 1, features: ["Intake"], topics: ["Walter", "martens"], in: context)
        let resolver = TopicResolver(hiddenKinds: [.person], people: TopicResolver.personNames(["Walter Martens"]))
        let sections = RefinementListGrouper.sections(rows([call]), by: .topic, resolver: resolver, status: { _ in .notBuilt })
        XCTAssertEqual(sections.map(\.title), ["No Topics"])
    }
}
