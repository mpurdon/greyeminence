import XCTest
@testable import Grey_Eminence

/// Master account plus per-feature overrides: every choice must resolve to
/// a real profile and region, chains must end, and the pre-0.50 embedding
/// keys must come across intact.
final class AIAccountSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "AIAccountSettingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        defaults.set("claude-code-bedrock", forKey: AIAccountSettings.masterProfileKey)
        defaults.set("us-east-2", forKey: AIAccountSettings.masterRegionKey)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func region(_ profile: String) -> String? {
        ["gitf": "us-east-1", "secondbrain": "eu-west-1"][profile]
    }

    // MARK: - Stored form

    func testChoiceRoundTripsThroughStoredValue() {
        for choice in [AIAccountChoice.master, .sameAs(.embeddings), .profile("gitf")] {
            XCTAssertEqual(AIAccountChoice(storedValue: choice.storedValue), choice)
        }
        XCTAssertNil(AIAccountChoice(storedValue: "profile:"))
        XCTAssertNil(AIAccountChoice(storedValue: "sameAs:nonsense"))
        XCTAssertNil(AIAccountChoice(storedValue: "garbage"))
    }

    // MARK: - Resolution

    func testUnsetSlotFollowsTheMaster() {
        let resolved = AIAccountSettings.resolved(for: .embeddings, defaults, profileRegion: region)
        XCTAssertEqual(resolved, ResolvedAIAccount(profile: "claude-code-bedrock", region: "us-east-2", isMaster: true))
    }

    func testProfileChoiceUsesTheProfilesOwnRegion() {
        AIAccountSettings.setChoice(.profile("gitf"), for: .embeddings, defaults)
        let resolved = AIAccountSettings.resolved(for: .embeddings, defaults, profileRegion: region)
        XCTAssertEqual(resolved, ResolvedAIAccount(profile: "gitf", region: "us-east-1", isMaster: false))
    }

    func testRegionOverrideBeatsTheProfilesRegion() {
        AIAccountSettings.setChoice(.profile("gitf"), for: .embeddings, defaults)
        AIAccountSettings.setRegionOverride("us-west-2", for: .embeddings, defaults)
        XCTAssertEqual(AIAccountSettings.resolved(for: .embeddings, defaults, profileRegion: region).region, "us-west-2")
    }

    func testProfileWithoutARegionFallsBackToTheMasters() {
        AIAccountSettings.setChoice(.profile("mystery"), for: .frameAnalysis, defaults)
        XCTAssertEqual(AIAccountSettings.resolved(for: .frameAnalysis, defaults, profileRegion: region).region, "us-east-2")
    }

    func testSameAsFollowsTheOtherSlot() {
        AIAccountSettings.setChoice(.profile("gitf"), for: .embeddings, defaults)
        AIAccountSettings.setChoice(.sameAs(.embeddings), for: .frameAnalysis, defaults)
        let resolved = AIAccountSettings.resolved(for: .frameAnalysis, defaults, profileRegion: region)
        XCTAssertEqual(resolved, ResolvedAIAccount(profile: "gitf", region: "us-east-1", isMaster: false))
    }

    func testSameAsUsesTheTargetSlotsRegionOverride() {
        AIAccountSettings.setChoice(.profile("gitf"), for: .embeddings, defaults)
        AIAccountSettings.setRegionOverride("us-west-2", for: .embeddings, defaults)
        AIAccountSettings.setChoice(.sameAs(.embeddings), for: .frameAnalysis, defaults)
        XCTAssertEqual(AIAccountSettings.resolved(for: .frameAnalysis, defaults, profileRegion: region).region, "us-west-2")
    }

    func testSameAsCycleFallsBackToMaster() {
        AIAccountSettings.setChoice(.sameAs(.embeddings), for: .frameAnalysis, defaults)
        AIAccountSettings.setChoice(.sameAs(.frameAnalysis), for: .embeddings, defaults)
        XCTAssertTrue(AIAccountSettings.resolved(for: .frameAnalysis, defaults, profileRegion: region).isMaster)
        XCTAssertTrue(AIAccountSettings.resolved(for: .embeddings, defaults, profileRegion: region).isMaster)
    }

    func testSettingMasterRemovesTheKey() {
        AIAccountSettings.setChoice(.profile("gitf"), for: .embeddings, defaults)
        AIAccountSettings.setChoice(.master, for: .embeddings, defaults)
        XCTAssertNil(defaults.string(forKey: AIAccountSettings.choiceKey(.embeddings)))
    }

    // MARK: - Legacy keys

    func testLegacyEmbeddingOverrideMigratesToTheSlot() {
        defaults.set("gitf", forKey: AIAccountSettings.legacyEmbeddingProfileKey)
        defaults.set("us-east-1", forKey: AIAccountSettings.legacyEmbeddingRegionKey)

        AIAccountSettings.migrateLegacyKeys(defaults)

        XCTAssertEqual(AIAccountSettings.choice(for: .embeddings, defaults), .profile("gitf"))
        XCTAssertEqual(AIAccountSettings.regionOverride(for: .embeddings, defaults), "us-east-1")
        XCTAssertNil(defaults.string(forKey: AIAccountSettings.legacyEmbeddingProfileKey))
        XCTAssertNil(defaults.string(forKey: AIAccountSettings.legacyEmbeddingRegionKey))
    }

    func testLegacyBlankMeansMasterAndIsCleared() {
        defaults.set("", forKey: AIAccountSettings.legacyEmbeddingProfileKey)
        AIAccountSettings.migrateLegacyKeys(defaults)
        XCTAssertEqual(AIAccountSettings.choice(for: .embeddings, defaults), .master)
        XCTAssertNil(defaults.object(forKey: AIAccountSettings.legacyEmbeddingProfileKey))
    }

    func testMigrationNeverOverwritesAnExistingChoice() {
        AIAccountSettings.setChoice(.profile("secondbrain"), for: .embeddings, defaults)
        defaults.set("gitf", forKey: AIAccountSettings.legacyEmbeddingProfileKey)
        AIAccountSettings.migrateLegacyKeys(defaults)
        XCTAssertEqual(AIAccountSettings.choice(for: .embeddings, defaults), .profile("secondbrain"))
    }
}
