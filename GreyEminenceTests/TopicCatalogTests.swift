import XCTest
import SwiftData
@testable import Grey_Eminence

@MainActor
final class TopicCatalogTests: XCTestCase {

    // MARK: - Catalog

    func testAliasesCountUnderTheirCanonicalAndTakeItsKind() {
        var catalog = TopicCatalog()
        catalog.apply(kind: .person, canonical: "Carlos Ayala Gonzalez", to: "carlos", version: 1)
        catalog.apply(kind: .person, canonical: nil, to: "Carlos Ayala Gonzalez", version: 1)

        XCTAssertEqual(catalog.key(for: " Carlos "), "carlos ayala gonzalez")
        XCTAssertEqual(catalog.displayName(for: "carlos"), "Carlos Ayala Gonzalez")
        XCTAssertNil(catalog.displayName(for: "Carlos Ayala Gonzalez"), "a canonical is its own name")

        var edited = catalog
        edited.entries["carlos ayala gonzalez"]?.kind = .organization
        XCTAssertEqual(edited.kind(for: "carlos"), .organization, "an alias follows its canonical's kind")
    }

    func testAliasChainsResolveAndCyclesStop() {
        var catalog = TopicCatalog()
        catalog.apply(kind: .technology, canonical: "Dynamo", to: "ddb", version: 1)
        catalog.apply(kind: .technology, canonical: "DynamoDB", to: "dynamo", version: 1)
        XCTAssertEqual(catalog.key(for: "ddb"), "dynamodb")
        XCTAssertEqual(catalog.displayName(for: "ddb"), "DynamoDB")

        catalog.apply(kind: .concept, canonical: "b", to: "a", version: 1)
        catalog.apply(kind: .concept, canonical: "a", to: "b", version: 1)
        XCTAssertEqual(catalog.key(for: "a"), "b", "a cycle stops instead of looping")
    }

    func testASelfAliasIsDropped() {
        var catalog = TopicCatalog()
        catalog.apply(kind: .technology, canonical: " AWS ", to: "aws", version: 1)
        XCTAssertNil(catalog.entry(for: "aws")?.canonical)
    }

    func testYourChoicesSurviveReclassification() {
        var catalog = TopicCatalog()
        catalog.apply(kind: .person, canonical: "Milo Smith", to: "Milo", version: 1)
        catalog.entries["milo"]?.kind = .service
        catalog.entries["milo"]?.kindIsUserSet = true
        catalog.entries["milo"]?.canonical = nil
        catalog.entries["milo"]?.aliasIsUserSet = true

        catalog.apply(kind: .person, canonical: "Milo Smith", to: "milo", version: 2)
        XCTAssertEqual(catalog.entry(for: "milo")?.kind, .service)
        XCTAssertNil(catalog.entry(for: "milo")?.canonical)
        XCTAssertFalse(catalog.needsClassifying("milo", version: 3), "fully settled by you")
    }

    func testWhatNeedsClassifying() {
        var catalog = TopicCatalog()
        XCTAssertTrue(catalog.needsClassifying("Jira", version: 1), "never seen")
        catalog.apply(kind: .technology, canonical: nil, to: "Jira", version: 1)
        XCTAssertFalse(catalog.needsClassifying("jira", version: 1))
        XCTAssertTrue(catalog.needsClassifying("jira", version: 2), "a newer prompt re-asks")
        catalog.apply(kind: .person, canonical: nil, to: "Walter Martens")
        XCTAssertFalse(catalog.needsClassifying("Walter Martens", version: 2), "a contact's name never needs the model")
    }

    func testCatalogRoundTripsAndUnknownKindsReadAsOther() throws {
        var catalog = TopicCatalog()
        catalog.apply(kind: .place, canonical: nil, to: "Austin", version: 1)
        let data = try JSONEncoder().encode(catalog)
        XCTAssertEqual(try JSONDecoder().decode(TopicCatalog.self, from: data), catalog)

        let future = #"{"entries":{"x":{"kind":"galaxy","kindIsUserSet":false,"aliasIsUserSet":false}}}"#
        XCTAssertEqual(try JSONDecoder().decode(TopicCatalog.self, from: Data(future.utf8)).entry(for: "x")?.kind, .other)
    }

    func testACatalogFromBeforeAliasVersioningStillLoads() throws {
        // The shape 0.52.0 wrote: no aliasesCheckedVersion.
        let stored = #"{"entries":{"carlos":{"kind":"person","canonical":"Carlos Ayala Gonzalez","kindIsUserSet":false,"aliasIsUserSet":false,"version":1}}}"#
        let catalog = try JSONDecoder().decode(TopicCatalog.self, from: Data(stored.utf8))
        XCTAssertEqual(catalog.entry(for: "carlos")?.canonical, "Carlos Ayala Gonzalez")
        XCTAssertNil(catalog.aliasesCheckedVersion, "so the one full check still runs")
    }

    func testResolverHidesKindsAndFallsBackToContactNames() {
        var catalog = TopicCatalog()
        catalog.apply(kind: .service, canonical: nil, to: "Milo", version: 1)
        let resolver = TopicResolver(catalog: catalog, hiddenKinds: [.person], people: TopicResolver.personNames(["Walter Martens"]))
        XCTAssertEqual(resolver.resolve("Milo")?.kind, .service)
        XCTAssertNil(resolver.resolve("walter"), "an unclassified contact name counts as a person")
        XCTAssertNil(resolver.resolve("  "))
        XCTAssertEqual(resolver.resolve("Brand new")?.kind, nil, "unclassified topics still show")
    }

    func testKindSetRoundTrips() {
        XCTAssertEqual(TopicKind.set(from: "person,place,bogus"), [.person, .place])
        XCTAssertEqual(TopicKind.raw([.place, .person]), "person,place")
    }

    // MARK: - Alias checks (cases from a real library)

    private let contacts = [
        "Walter Martens", "Evan Walker", "Matt Wheatley", "Matthew Purdon", "Steven Goodman",
        "Steve Gossard", "Stephen Smith", "Leah Stephens", "José Luna", "Damian Kuna-Bronkowski",
        "Kelly Peterson", "Kelly Hough", "Zhihong Chen", "Parveen Sharma", "Carlos Ayala Gonzalez",
        "Carl Anthony Carandan", "Eric Nicholas", "Erick Silva",
    ]

    func testPersonAliasesThatHold() {
        let check = TopicAliasCheck(contactNames: contacts)
        for (alias, name) in [
            ("walter", "Walter Martens"),          // not Evan Walker's surname
            ("stephen", "Stephen Smith"),          // not Leah Stephens
            ("carlos", "Carlos Ayala Gonzalez"),   // not Carl
            ("luna", "José Luna"),                 // not Kuna
            ("praveen sharma", "Parveen Sharma"),
            ("steve gussard", "Steve Gossard"),
            ("zi hong", "Zhihong Chen"),
            ("matt purdon", "Matthew Purdon"),
        ] {
            XCTAssertTrue(check.isPlausible(alias: alias, canonical: name, kind: .person), "\(alias) → \(name)")
        }
    }

    func testPersonAliasesThatDont() {
        let check = TopicAliasCheck(contactNames: contacts)
        for (alias, name) in [
            ("steven smith", "Steven Goodman"),    // another surname
            ("walter's role", "Walter Martens"),   // not a name
            ("matt", "Matt Wheatley"),             // two Matts
            ("steve", "Steven Goodman"),           // Steven, Steve
            ("kelly", "Kelly Peterson"),           // two Kellys
            ("eric", "Eric Nicholas"),             // Eric, Erick
            ("franco", "José Luna"),               // not his name at all
        ] {
            XCTAssertFalse(check.isPlausible(alias: alias, canonical: name, kind: .person), "\(alias) → \(name)")
        }
    }

    func testOtherAliasesNeedASpellingOrAnAcronym() {
        let check = TopicAliasCheck(contactNames: [])
        XCTAssertTrue(check.isPlausible(alias: "testrails", canonical: "TestRail", kind: .technology))
        XCTAssertTrue(check.isPlausible(alias: "route53", canonical: "Route 53", kind: .technology))
        XCTAssertTrue(check.isPlausible(alias: "fmla", canonical: "Family and Medical Leave Act", kind: .concept))
        XCTAssertTrue(check.isPlausible(alias: "ga", canonical: "Google Analytics", kind: .technology))
        XCTAssertFalse(check.isPlausible(alias: "athena", canonical: "Sumo Logic", kind: .technology))
        XCTAssertFalse(check.isPlausible(alias: "ai watermarking", canonical: "T70", kind: .concept), "a topic ID is not a name")
    }

    func testCleanupKeepsAliasesYouSet() {
        var catalog = TopicCatalog()
        catalog.apply(kind: .technology, canonical: "Sumo Logic", to: "athena", version: 1)
        catalog.apply(kind: .technology, canonical: "Sumo Logic", to: "sumo", version: 1)
        catalog.apply(kind: .concept, canonical: "T11", to: "ai integration", version: 1)
        catalog.entries["mine"] = .init(kind: .other, canonical: "Unrelated", aliasIsUserSet: true)
        catalog.dropImplausibleAliases(contactNames: [])
        XCTAssertNil(catalog.entry(for: "athena")?.canonical)
        XCTAssertNil(catalog.entry(for: "ai integration")?.canonical)
        XCTAssertEqual(catalog.entry(for: "sumo")?.canonical, "Sumo Logic")
        XCTAssertEqual(catalog.entry(for: "mine")?.canonical, "Unrelated")
    }

    func testClassifierIgnoresTopicIDsAsCanonicals() {
        let parsed = TopicClassifier.parse(response: #"{"topics":[{"id":"T1","kind":"concept","canonical":"T70"}]}"#, count: 1)
        XCTAssertEqual(parsed[0], .init(kind: .concept, canonical: nil))
    }

    // MARK: - Classifier

    func testClassifierParsesByPositionAndDropsJunk() {
        let response = """
        ```json
        {"topics":[
          {"id":"T1","kind":"Person","canonical":"Walter Martens"},
          {"id":"t2","kind":"technology","canonical":null},
          {"id":"T3","kind":"planet"},
          {"id":"T9","kind":"service"},
          {"id":"T4","kind":"service","canonical":"  "}
        ]}
        ```
        """
        let parsed = TopicClassifier.parse(response: response, count: 4)
        XCTAssertEqual(parsed[0], .init(kind: .person, canonical: "Walter Martens"))
        XCTAssertEqual(parsed[1], .init(kind: .technology, canonical: nil))
        XCTAssertNil(parsed[2], "an unknown kind is retried next run")
        XCTAssertEqual(parsed[3], .init(kind: .service, canonical: nil))
        XCTAssertEqual(parsed.count, 3)
        XCTAssertTrue(TopicClassifier.parse(response: "no", count: 2).isEmpty)
    }

    func testClassifierCatalogueGivesContext() {
        let sample = TopicClassifier.Sample(key: "milo", label: "Milo", meetingCount: 3, meetingTitle: "Lead sync", neighbours: ["Lead Service", "Mongo"])
        XCTAssertEqual(TopicClassifier.catalogue([sample]), "T1: Milo — in \"Lead sync\" with: Lead Service, Mongo")
        XCTAssertEqual(TopicClassifier.peopleList([" Zed ", "Amy", "Amy", ""]), "Amy; Zed")
        XCTAssertEqual(TopicClassifier.peopleList([]), "None recorded.")
    }

    func testSamplesUseEachMeetingsLatestInsight() throws {
        let container = try ModelContainer(for: Meeting.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        func meeting(_ title: String, _ day: Double, _ topics: [[String]]) {
            let meeting = Meeting(title: title, status: .completed)
            meeting.date = Date(timeIntervalSince1970: day * 86_400)
            context.insert(meeting)
            for (i, list) in topics.enumerated() {
                let insight = MeetingInsight(summary: "s", topics: list)
                insight.createdAt = Date(timeIntervalSince1970: Double(i))
                context.insert(insight)
                insight.meeting = meeting
            }
        }
        meeting("Old", 1, [["Milo", "Mongo"]])
        meeting("New", 5, [["stale"], ["milo", "Jira"]])

        let samples = TopicClassifier.samples(from: try context.fetch(FetchDescriptor<MeetingInsight>()))
        XCTAssertEqual(samples.map(\.key), ["milo", "jira", "mongo"], "most meetings first; the superseded insight is ignored")
        XCTAssertEqual(samples[0].meetingCount, 2)
        XCTAssertEqual(samples[0].meetingTitle, "New")
        XCTAssertEqual(samples[0].neighbours, ["Jira"])
    }
}
