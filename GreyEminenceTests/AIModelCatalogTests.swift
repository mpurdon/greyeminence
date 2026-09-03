import XCTest
@testable import Grey_Eminence

/// Pins the legacy-ID migration: a user upgrading from a build that stored
/// the dated 4-series IDs must land on the current models without touching
/// Settings, and hand-entered IDs must pass through untouched.
final class AIModelCatalogTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AIModelCatalogTests")!
        defaults.removePersistentDomain(forName: "AIModelCatalogTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AIModelCatalogTests")
        super.tearDown()
    }

    func testLegacyIDsCanonicaliseToCurrentModels() {
        XCTAssertEqual(AIModelCatalog.canonical("claude-opus-4-20250514"), AIModelCatalog.opus)
        XCTAssertEqual(AIModelCatalog.canonical("claude-sonnet-4-20250514"), AIModelCatalog.sonnet)
        XCTAssertEqual(AIModelCatalog.canonical("claude-haiku-4-5-20251001"), AIModelCatalog.haiku)
    }

    func testCurrentAndUnknownIDsPassThrough() {
        XCTAssertEqual(AIModelCatalog.canonical(AIModelCatalog.sonnet), AIModelCatalog.sonnet)
        XCTAssertEqual(AIModelCatalog.canonical("claude-fable-5-1"), "claude-fable-5-1")
        XCTAssertEqual(AIModelCatalog.canonical(""), "")
    }

    func testMigrationRewritesStoredLegacyIDs() {
        defaults.set("claude-sonnet-4-20250514", forKey: AIModelCatalog.mainModelKey)
        defaults.set("claude-haiku-4-5-20251001", forKey: ScreenShareSettings.frameAnalysisModelKey)
        AIModelCatalog.migrateStoredDefaults(defaults)
        XCTAssertEqual(defaults.string(forKey: AIModelCatalog.mainModelKey), AIModelCatalog.sonnet)
        XCTAssertEqual(defaults.string(forKey: ScreenShareSettings.frameAnalysisModelKey), AIModelCatalog.haiku)
    }

    func testMigrationLeavesCurrentAndUnsetValuesAlone() {
        defaults.set(AIModelCatalog.opus, forKey: AIModelCatalog.mainModelKey)
        // Frame model deliberately unset: "same as main model" is the empty
        // string, and a missing key must stay missing so the Haiku default applies.
        AIModelCatalog.migrateStoredDefaults(defaults)
        XCTAssertEqual(defaults.string(forKey: AIModelCatalog.mainModelKey), AIModelCatalog.opus)
        XCTAssertNil(defaults.string(forKey: ScreenShareSettings.frameAnalysisModelKey))
    }

    func testBedrockFoundationIDsForCurrentModels() {
        XCTAssertEqual(AIClientFactory.foundationModelId(for: AIModelCatalog.opus), "anthropic.claude-opus-5")
        XCTAssertEqual(AIClientFactory.foundationModelId(for: AIModelCatalog.sonnet), "anthropic.claude-sonnet-5")
        XCTAssertEqual(AIClientFactory.foundationModelId(for: AIModelCatalog.haiku), "global.anthropic.claude-haiku-4-5-20251001-v1:0")
        // A legacy stored ID resolves to the same foundation ID as its replacement.
        XCTAssertEqual(AIClientFactory.foundationModelId(for: "claude-sonnet-4-20250514"), "anthropic.claude-sonnet-5")
    }

    func testSystemPromptBlockCarriesCacheBreakpoint() throws {
        let data = try JSONEncoder().encode(SystemPromptBlock.cached("You are a helpful assistant."))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["type"] as? String, "text")
        XCTAssertEqual(json[0]["text"] as? String, "You are a helpful assistant.")
        XCTAssertEqual((json[0]["cache_control"] as? [String: String])?["type"], "ephemeral")
    }
}
