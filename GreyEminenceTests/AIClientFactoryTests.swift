import XCTest
@testable import Grey_Eminence

/// Pure tests for the frame-analysis model resolver — no UserDefaults,
/// no network.
final class AIClientFactoryTests: XCTestCase {

    private let haiku = AIModelCatalog.haiku
    private let sonnet = AIModelCatalog.sonnet

    func testAnthropicUsesPreferredHaiku() {
        let choice = AIClientFactory.frameAnalysisModel(
            preferred: haiku, mainModel: sonnet,
            provider: .anthropic, haikuProfileAvailable: false
        )
        XCTAssertEqual(choice.model, haiku)
        XCTAssertFalse(choice.fellBackToMainModel)
    }

    func testBedrockWithHaikuProfileUsesHaiku() {
        let choice = AIClientFactory.frameAnalysisModel(
            preferred: haiku, mainModel: sonnet,
            provider: .bedrock, haikuProfileAvailable: true
        )
        XCTAssertEqual(choice.model, haiku)
        XCTAssertFalse(choice.fellBackToMainModel)
    }

    func testBedrockWithoutHaikuProfileFallsBackToMainModel() {
        let choice = AIClientFactory.frameAnalysisModel(
            preferred: haiku, mainModel: sonnet,
            provider: .bedrock, haikuProfileAvailable: false
        )
        XCTAssertEqual(choice.model, sonnet)
        XCTAssertTrue(choice.fellBackToMainModel)
    }

    func testEmptyPreferenceMeansMainModel() {
        for provider in [AIProvider.anthropic, .bedrock] {
            let choice = AIClientFactory.frameAnalysisModel(
                preferred: "", mainModel: sonnet,
                provider: provider, haikuProfileAvailable: true
            )
            XCTAssertEqual(choice.model, sonnet)
            XCTAssertFalse(choice.fellBackToMainModel)
        }
    }

    func testPreferredEqualToMainModelIsNotAFallback() {
        let choice = AIClientFactory.frameAnalysisModel(
            preferred: sonnet, mainModel: sonnet,
            provider: .bedrock, haikuProfileAvailable: false
        )
        XCTAssertEqual(choice.model, sonnet)
        XCTAssertFalse(choice.fellBackToMainModel)
    }

    func testHaikuMainModelStaysOnHaikuWithoutProfile() {
        // Main model IS haiku — nothing to fall back to; the resolver must
        // not loop the choice through the bedrock guard.
        let choice = AIClientFactory.frameAnalysisModel(
            preferred: haiku, mainModel: haiku,
            provider: .bedrock, haikuProfileAvailable: false
        )
        XCTAssertEqual(choice.model, haiku)
        XCTAssertFalse(choice.fellBackToMainModel)
    }
}
