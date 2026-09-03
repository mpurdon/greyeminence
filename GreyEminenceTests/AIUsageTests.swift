import XCTest
@testable import Grey_Eminence

/// Usage decoding, pricing family resolution, and ledger rollups — all pure.
final class AIUsageTests: XCTestCase {

    // MARK: - Usage decode

    func testDecodeFullAnthropicResponse() {
        let body = Data("""
        {
          "id": "msg_01",
          "content": [{"type": "text", "text": "hi"}],
          "usage": {
            "input_tokens": 12340,
            "output_tokens": 512,
            "cache_read_input_tokens": 900,
            "cache_creation_input_tokens": 100
          }
        }
        """.utf8)
        let usage = AIUsage.decode(fromResponseBody: body)
        XCTAssertEqual(usage, AIUsage(inputTokens: 12340, outputTokens: 512, cacheReadTokens: 900, cacheWriteTokens: 100))
    }

    func testDecodeBedrockStyleResponseWithoutCacheFields() {
        // Bedrock's anthropic passthrough omits the cache fields.
        let body = Data("""
        {"content": [{"type": "text", "text": "hi"}], "usage": {"input_tokens": 42, "output_tokens": 7}}
        """.utf8)
        let usage = AIUsage.decode(fromResponseBody: body)
        XCTAssertEqual(usage, AIUsage(inputTokens: 42, outputTokens: 7, cacheReadTokens: 0, cacheWriteTokens: 0))
    }

    func testDecodeMissingUsageReturnsNil() {
        let body = Data("""
        {"content": [{"type": "text", "text": "hi"}]}
        """.utf8)
        XCTAssertNil(AIUsage.decode(fromResponseBody: body))
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(AIUsage.decode(fromResponseBody: Data("not json".utf8)))
    }

    // MARK: - Pricing family

    private let trajector = TrajectorSettings(
        sonnetModel: "arn:aws:bedrock:us-east-1:123:application-inference-profile/sss",
        opusModel: "arn:aws:bedrock:us-east-1:123:application-inference-profile/ooo",
        haikuModel: "arn:aws:bedrock:us-east-1:123:application-inference-profile/hhh",
        awsProfile: nil,
        awsRegion: nil
    )

    func testFamilyBySubstring() {
        XCTAssertEqual(AIPricing.family(forModelIdentifier: "anthropic:claude-haiku-4-5-20251001", settings: nil), .haiku)
        XCTAssertEqual(AIPricing.family(forModelIdentifier: "bedrock:us-east-1:anthropic.claude-sonnet-4-20250514-v1:0", settings: nil), .sonnet)
        XCTAssertEqual(AIPricing.family(forModelIdentifier: "anthropic:claude-opus-4-20250514", settings: nil), .opus)
    }

    func testFamilyByProfileARN() {
        let id = "bedrock:us-east-1:arn:aws:bedrock:us-east-1:123:application-inference-profile/hhh"
        XCTAssertEqual(AIPricing.family(forModelIdentifier: id, settings: trajector), .haiku)
        XCTAssertNil(AIPricing.family(forModelIdentifier: id, settings: nil))
    }

    func testFamilyUnknownIsNil() {
        XCTAssertNil(AIPricing.family(forModelIdentifier: "bedrock:us-east-1:arn:aws:bedrock:us-east-1:123:application-inference-profile/zzz", settings: trajector))
    }

    func testCostComputation() {
        // 1M input + 1M output on Haiku = $1 + $5.
        let usage = AIUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 0, cacheWriteTokens: 0)
        XCTAssertEqual(AIPricing.haiku.cost(of: usage), 6.0, accuracy: 0.0001)
        // Cache reads bill at 10% of input.
        let cached = AIUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000, cacheWriteTokens: 0)
        XCTAssertEqual(AIPricing.sonnet.cost(of: cached), 0.2, accuracy: 0.0001)
    }

    // MARK: - Aggregator

    private func line(
        purpose: AIUsagePurpose,
        model: String,
        input: Int,
        output: Int
    ) -> AIUsageAggregator.Line {
        AIUsageAggregator.Line(
            purpose: purpose,
            modelIdentifier: model,
            usage: AIUsage(inputTokens: input, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: 0)
        )
    }

    func testTotalsSumAcrossLines() {
        let lines = [
            line(purpose: .frameAnalysis, model: "anthropic:claude-haiku-4-5-20251001", input: 1_000_000, output: 0),
            line(purpose: .transcriptFinal, model: "anthropic:claude-sonnet-4-20250514", input: 0, output: 1_000_000),
        ]
        let totals = AIUsageAggregator.totals(lines, settings: nil)
        XCTAssertEqual(totals.inputTokens, 1_000_000)
        XCTAssertEqual(totals.outputTokens, 1_000_000)
        XCTAssertEqual(totals.estimatedCost, 11.0, accuracy: 0.0001)  // $1 haiku in + $10 sonnet out
        XCTAssertTrue(totals.pricedEverything)
    }

    func testTotalsFlagUnpricedModels() {
        let lines = [
            line(purpose: .other, model: "mystery-model", input: 500, output: 500),
            line(purpose: .ask, model: "anthropic:claude-haiku-4-5-20251001", input: 1000, output: 0),
        ]
        let totals = AIUsageAggregator.totals(lines, settings: nil)
        XCTAssertFalse(totals.pricedEverything)
        XCTAssertEqual(totals.inputTokens, 1500)  // tokens still counted
        XCTAssertGreaterThan(totals.estimatedCost, 0)  // priced lines still estimated
    }

    func testByPurposeGroupsAndOrdersByCost() {
        let lines = [
            line(purpose: .frameAnalysis, model: "anthropic:claude-haiku-4-5-20251001", input: 100_000, output: 10_000),
            line(purpose: .frameAnalysis, model: "anthropic:claude-haiku-4-5-20251001", input: 100_000, output: 10_000),
            line(purpose: .transcriptFinal, model: "anthropic:claude-sonnet-4-20250514", input: 2_000_000, output: 100_000),
        ]
        let grouped = AIUsageAggregator.byPurpose(lines, settings: nil)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].purpose, .transcriptFinal)  // costlier first
        XCTAssertEqual(grouped[1].totals.inputTokens, 200_000)  // both frame lines merged
    }

    func testPurposeGroupMapping() {
        XCTAssertEqual(AIUsagePurpose.transcriptInitial.group, .transcript)
        XCTAssertEqual(AIUsagePurpose.transcriptRolling.group, .transcript)
        XCTAssertEqual(AIUsagePurpose.transcriptFinal.group, .finalAnalysis)
        XCTAssertEqual(AIUsagePurpose.reanalysis.group, .finalAnalysis)
        XCTAssertEqual(AIUsagePurpose.frameAnalysis.group, .screenShare)
        XCTAssertEqual(AIUsagePurpose.sessionSynthesis.group, .screenShare)
        for purpose in [AIUsagePurpose.ask, .interview, .prep, .other] {
            XCTAssertEqual(purpose.group, .other)
        }
    }

    func testByGroupMergesAndOrdersDeclaratively() {
        let lines = [
            line(purpose: .frameAnalysis, model: "anthropic:claude-haiku-4-5-20251001", input: 100, output: 10),
            line(purpose: .sessionSynthesis, model: "anthropic:claude-sonnet-4-20250514", input: 50, output: 5),
            line(purpose: .transcriptRolling, model: "anthropic:claude-sonnet-4-20250514", input: 30, output: 3),
        ]
        let groups = AIUsageAggregator.byGroup(lines, settings: nil)
        // Fixed declaration order, empty groups (finalAnalysis, other) omitted.
        XCTAssertEqual(groups.map(\.group), [.transcript, .screenShare])
        let shares = groups[1]
        XCTAssertEqual(shares.totals.inputTokens, 150)  // both purposes merged
        XCTAssertEqual(shares.purposes.count, 2)
    }

    func testCompactTokens() {
        XCTAssertEqual(AIUsageAggregator.compactTokens(950), "950")
        XCTAssertEqual(AIUsageAggregator.compactTokens(12_340), "12k")
        XCTAssertEqual(AIUsageAggregator.compactTokens(1_234_000), "1.2M")
    }

    // MARK: - Attribution context

    func testAttributionOutermostWins() async {
        let inner = await AIUsageContext.attribute(.reanalysis, meetingID: nil) {
            await AIUsageContext.attribute(.transcriptFinal, meetingID: nil) {
                AIUsageContext.current?.purpose
            }
        }
        XCTAssertEqual(inner, .reanalysis)
    }

    func testAttributionDefaultsWhenUnset() {
        XCTAssertNil(AIUsageContext.current)
    }
}
