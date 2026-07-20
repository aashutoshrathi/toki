import XCTest
@testable import Toki

final class ModelPricingTests: XCTestCase {
    func testOpusRatesMatchPublishedPricing() {
        let rate = ModelPricing.rate(forModel: "claude-opus-4-8")
        XCTAssertEqual(rate?.input, 5)
        XCTAssertEqual(rate?.output, 25)
    }

    func testSonnetRatesMatchPublishedPricing() {
        let rate = ModelPricing.rate(forModel: "claude-sonnet-5")
        XCTAssertEqual(rate?.input, 3)
        XCTAssertEqual(rate?.output, 15)
    }

    // Cache writes bill at 1.25x input and reads at 0.1x. Pricing either at the full input
    // rate is the mistake that would silently inflate every long session's cost.
    func testCacheMultipliersDeriveFromInputRate() {
        let rate = ModelPricing.rate(forModel: "claude-opus-4-8")
        XCTAssertEqual(rate?.cacheWrite, 6.25)
        XCTAssertEqual(rate?.cacheRead, 0.5)
    }

    // "claude-opus-4-8" must not be captured by the shorter legacy "claude-opus-4" entry,
    // which carries the much higher Opus 4.0 rate.
    func testLongestPrefixWins() {
        XCTAssertEqual(ModelPricing.rate(forModel: "claude-opus-4-8")?.input, 5)
        XCTAssertEqual(ModelPricing.rate(forModel: "claude-opus-4-0")?.input, 15)
    }

    func testDatedVariantResolvesToBaseModel() {
        XCTAssertEqual(ModelPricing.rate(forModel: "claude-haiku-4-5-20251001")?.input, 1)
    }

    func testUnknownModelHasNoRate() {
        XCTAssertNil(ModelPricing.rate(forModel: "gpt-5"))
        XCTAssertNil(ModelPricing.costUSD(
            model: "gpt-5", inputTokens: 1000, outputTokens: 1000,
            cacheWriteTokens: 0, cacheReadTokens: 0
        ))
    }

    func testCostCombinesAllFourTokenClasses() {
        // 1M each on Opus 4.8: 5 + 25 + 6.25 + 0.5 = 36.75
        let cost = ModelPricing.costUSD(
            model: "claude-opus-4-8",
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheWriteTokens: 1_000_000, cacheReadTokens: 1_000_000
        )
        XCTAssertEqual(try XCTUnwrap(cost), 36.75, accuracy: 0.0001)
    }

    func testClaudeSessionCostPricesCacheTokensSeparately() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":1000000}}}
        """
        let usage = AgentSessionResolver.claudeUsage(fromJSONLData: Data(jsonl.utf8))
        // $5 input + $0.50 cache read. Pricing the cache read as input would give $10.
        XCTAssertEqual(try XCTUnwrap(usage?.cost), 5.5, accuracy: 0.0001)
    }

    // A /model switch mid-session means each line must bill at its own model's rate.
    func testCostAccumulatesAcrossModelSwitch() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let usage = AgentSessionResolver.claudeUsage(fromJSONLData: Data(jsonl.utf8))
        XCTAssertEqual(try XCTUnwrap(usage?.cost), 8, accuracy: 0.0001)  // $5 + $3
    }

    func testSessionWithoutModelFieldStillReportsTokens() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        let usage = AgentSessionResolver.claudeUsage(fromJSONLData: Data(jsonl.utf8))
        XCTAssertNil(usage?.cost)
        XCTAssertEqual(usage?.tokensInput, 100)
    }

    func testSubCentSpendIsNotRenderedAsZero() {
        XCTAssertEqual(formatUSD(0.004), "<$0.01")
        XCTAssertEqual(formatUSD(0), "$0.00")
    }
}
