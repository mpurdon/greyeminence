import XCTest
@testable import Grey_Eminence

/// How the vocabulary reaches the mis-hearing repair pass. A flat list made
/// every term look equally likely, which is how a name weighted 1 got
/// substituted for a word the recogniser had merely garbled.
final class VocabularyContextTests: XCTestCase {

    private typealias Context = TranscriptCorrectionService.Context

    private func term(_ text: String, _ kind: TermKind, _ boost: Float) -> Context.Term {
        .init(text: text, kind: kind, boost: boost)
    }

    /// The real vocabulary as configured, which is the case that failed.
    private var realTerms: [Context.Term] {
        [
            term("Trajector", .company, 15), term("RDL", .document, 10),
            term("OLP", .project, 10), term("C-File", .document, 10),
            term("DDM", .system, 10), term("Milo", .system, 10),
            term("AIDC", .project, 10), term("Liran", .person, 14),
            term("Erin", .person, 20), term("Aaron", .person, 1),
        ]
    }

    func testTermsAreGroupedByKindAndOrderedByWeight() {
        let rendered = Context(title: "Sync", participants: [], terms: realTerms, topics: []).rendered
        XCTAssertTrue(rendered.contains("- People: Erin, Liran"), "highest weight first, and Aaron is not here")
        XCTAssertTrue(rendered.contains("- Companies: Trajector"))
        XCTAssertTrue(rendered.contains("- Projects: OLP, AIDC"))
        XCTAssertTrue(rendered.contains("- Documents and records: RDL, C-File"))
        XCTAssertTrue(rendered.contains("- Systems and tools: DDM, Milo"))
    }

    /// The bug: Aaron at weight 1 arrived indistinguishable from Erin at 20.
    func testABarelyEverTermIsQuarantinedRatherThanListedAsExpected() {
        let rendered = Context(title: "Sync", participants: [], terms: realTerms, topics: []).rendered
        let expectedSection = rendered.components(separatedBy: "Rarely mentioned")[0]
        XCTAssertFalse(expectedSection.contains("Aaron"), "a weight-1 term must not sit among the expected ones")
        XCTAssertTrue(rendered.contains("Rarely mentioned"))
        XCTAssertTrue(rendered.components(separatedBy: "Rarely mentioned")[1].contains("Aaron"))
    }

    func testParticipantsAreNamedAsAuthoritative() {
        let rendered = Context(title: "Sync", participants: ["Erin Shaw"], terms: realTerms, topics: []).rendered
        XCTAssertTrue(rendered.contains("prefer their names over any similar-sounding name"))
        XCTAssertTrue(rendered.contains("Erin Shaw"))
    }

    /// Listing an attendee again among the terms only dilutes the stronger
    /// statement that they are on the call.
    func testAPersonWhoIsAlreadyAParticipantIsNotRepeatedInTheTerms() {
        let terms = [term("Erin", .person, 20), term("Liran", .person, 14)]
        let rendered = Context(title: "Sync", participants: ["erin"], terms: terms, topics: []).rendered
        XCTAssertTrue(rendered.contains("- People: Liran"))
        XCTAssertFalse(rendered.contains("- People: Erin"))
    }

    func testKindGroupsAppearInAFixedOrderRegardlessOfInput() {
        let shuffled = [term("Zed", .other, 10), term("Ann", .person, 10), term("Acme", .company, 10)]
        let rendered = Context(title: "", participants: [], terms: shuffled, topics: []).rendered
        let people = try! XCTUnwrap(rendered.range(of: "- People"))
        let companies = try! XCTUnwrap(rendered.range(of: "- Companies"))
        let other = try! XCTUnwrap(rendered.range(of: "- Other terms"))
        XCTAssertTrue(people.lowerBound < companies.lowerBound)
        XCTAssertTrue(companies.lowerBound < other.lowerBound)
    }

    func testEmptyVocabularyRendersNoTermSections() {
        let rendered = Context(title: "Sync", participants: [], terms: [], topics: []).rendered
        XCTAssertFalse(rendered.contains("Terms to expect"))
        XCTAssertFalse(rendered.contains("Rarely mentioned"))
        XCTAssertEqual(rendered, "Meeting: Sync")
    }

    func testAnEntirelyEmptyContextStillSaysSomething() {
        XCTAssertEqual(Context(title: "", participants: [], terms: [], topics: []).rendered, "No additional context.")
    }

    /// Terms saved before kinds existed must survive the upgrade.
    func testLegacyTermsWithoutAKindDecodeAsOther() throws {
        let json = """
        [{"id":"F26D3C5E-0000-4000-8000-000000000001","text":"Trajector","boost":15}]
        """.data(using: .utf8)!
        let terms = try JSONDecoder().decode([VocabularyTerm].self, from: json)
        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].kind, .other)
        XCTAssertEqual(terms[0].boost, 15)
    }

    func testKindRoundTripsThroughJSON() throws {
        let original = VocabularyTerm(text: "C-File", boost: 10, kind: .document)
        let decoded = try JSONDecoder().decode(VocabularyTerm.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.kind, .document)
        XCTAssertEqual(decoded.text, "C-File")
    }
}
