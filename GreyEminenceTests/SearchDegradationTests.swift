import XCTest
import SwiftData
@testable import Grey_Eminence

/// When the query cannot be embedded, search must still run its keyword
/// half and say so — an expired AWS session used to surface as "nothing
/// matched", which sent people off to widen the date range.
@MainActor
final class SearchDegradationTests: XCTestCase {

    private final class FailingEmbedding: EmbeddingService, @unchecked Sendable {
        let modelIdentifier = "fixture"
        let isAvailable = true
        let maxConcurrency = 1
        var failure: String? = "profile gitf, us-east-1: Bedrock HTTP 403: token expired"
        var lastFailureDescription: String? { failure }
        func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]? { nil }
    }

    private final class WorkingEmbedding: EmbeddingService, @unchecked Sendable {
        let modelIdentifier = "fixture"
        let isAvailable = true
        let maxConcurrency = 1
        func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]? { [1, 0] }
    }

    private var container: ModelContainer!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: EmbeddingRecord.self, configurations: config)
    }

    private func records() -> [EmbeddingRecord] {
        let meeting = UUID()
        let rows: [(String, [Float])] = [
            ("Monte said classrooms were turning into coding factories", [1, 0]),
            ("We reviewed the quarterly budget and headcount plan", [0, 1]),
            ("Lunch is at noon on Thursday", [0.5, 0.5]),
        ]
        return rows.enumerated().map { index, row in
            let record = EmbeddingRecord(
                id: "r\(index)",
                sourceID: UUID(),
                sourceKind: .transcriptSegment,
                meetingID: meeting,
                meetingTitle: "Weekly sync",
                meetingDate: .now,
                text: row.0,
                vector: row.1,
                modelIdentifier: "fixture"
            )
            container.mainContext.insert(record)
            return record
        }
    }

    func testFallsBackToKeywordsAndReportsWhy() async {
        let fixture = records()
        let service = SemanticSearchService(records: { _ in fixture }, service: FailingEmbedding())

        let outcome = await service.searchReporting("classrooms as coding factories")

        XCTAssertEqual(outcome.degradation, .keywordOnly(reason: "profile gitf, us-east-1: Bedrock HTTP 403: token expired"))
        XCTAssertEqual(outcome.results.map(\.id), ["r0"], "only the record with a query term in it has any evidence")
    }

    func testKeywordOnlyWithNoMatchingTermsIsEmptyButStillExplained() async {
        let fixture = records()
        let service = SemanticSearchService(records: { _ in fixture }, service: FailingEmbedding())

        let outcome = await service.searchReporting("kubernetes migration")

        XCTAssertTrue(outcome.results.isEmpty)
        if case .keywordOnly? = outcome.degradation {} else {
            XCTFail("expected a keyword-only degradation, got \(String(describing: outcome.degradation))")
        }
    }

    func testFullStrengthSearchReportsNoDegradation() async {
        let fixture = records()
        let service = SemanticSearchService(records: { _ in fixture }, service: WorkingEmbedding())

        let outcome = await service.searchReporting("classrooms as coding factories")

        XCTAssertNil(outcome.degradation)
        XCTAssertEqual(outcome.results.first?.id, "r0")
        XCTAssertEqual(outcome.results.count, 3, "at full strength every candidate is ranked, not filtered")
    }
}
