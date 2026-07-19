import XCTest
@testable import Toki

final class SessionUsageTests: XCTestCase {
    // MARK: - AgentSessionUsage display formatting

    func testDisplayLineWithCostAndTokens() {
        let usage = AgentSessionUsage(cost: 0.05, tokensInput: 1200, tokensOutput: 500)
        XCTAssertEqual(usage.displayCost, "$0.05")
        XCTAssertTrue(usage.displayTokens.contains("1K in"))
        XCTAssertTrue(usage.displayTokens.contains("500 out"))
        XCTAssertTrue(usage.displayLine?.contains("$0.05") == true)
        XCTAssertTrue(usage.displayLine?.contains("1K in") == true)
    }

    func testDisplayLineWithTokensOnly() {
        let usage = AgentSessionUsage(cost: nil, tokensInput: 3400, tokensOutput: 1200)
        XCTAssertNil(usage.displayCost)
        XCTAssertTrue(usage.displayLine?.contains("3K in") == true)
        XCTAssertTrue(usage.displayLine?.contains("1K out") == true)
    }

    func testDisplayLineWithCostOnly() {
        let usage = AgentSessionUsage(cost: 0.10, tokensInput: 0, tokensOutput: 0)
        XCTAssertEqual(usage.displayCost, "$0.10")
        XCTAssertEqual(usage.displayLine, "$0.10")
    }

    func testDisplayLineWithZeroUsage() {
        let usage = AgentSessionUsage(cost: nil, tokensInput: 0, tokensOutput: 0)
        XCTAssertNil(usage.displayLine)
    }

    func testDisplayLineWithLargeTokenCounts() {
        let usage = AgentSessionUsage(cost: 1.23, tokensInput: 1_500_000, tokensOutput: 500_000)
        XCTAssertTrue(usage.displayLine?.contains("2M in") == true, "got \(usage.displayLine ?? "nil")")
        XCTAssertTrue(usage.displayLine?.contains("500K out") == true, "got \(usage.displayLine ?? "nil")")
        XCTAssertTrue(usage.displayLine?.contains("$1.23") == true)
    }

    // MARK: - Claude Code JSONL token parsing

    func testClaudeUsageFromSingleAssistantMessage() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":150,"output_tokens":75}}}
        """
        let data = Data(jsonl.utf8)
        let usage = AgentSessionResolver.claudeUsage(fromJSONLData: data)
        XCTAssertEqual(usage?.tokensInput, 150)
        XCTAssertEqual(usage?.tokensOutput, 75)
        XCTAssertNil(usage?.cost)
    }

    func testClaudeUsageFromMultipleAssistantMessages() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"user"}
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":200,"output_tokens":80}}}
        """
        let data = Data(jsonl.utf8)
        let usage = AgentSessionResolver.claudeUsage(fromJSONLData: data)
        XCTAssertEqual(usage?.tokensInput, 300)
        XCTAssertEqual(usage?.tokensOutput, 130)
    }

    func testClaudeUsageIgnoresNonAssistantLines() {
        let jsonl = """
        {"type":"session","id":"test-session"}
        {"type":"ai-title","customTitle":"Test"}
        {"type":"user","message":{"role":"user"}}
        """
        let data = Data(jsonl.utf8)
        XCTAssertNil(AgentSessionResolver.claudeUsage(fromJSONLData: data))
    }

    func testClaudeUsageHandlesMissingUsageBlock() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant"}}
        """
        let data = Data(jsonl.utf8)
        XCTAssertNil(AgentSessionResolver.claudeUsage(fromJSONLData: data))
    }

    func testClaudeUsageHandlesEmptyData() {
        XCTAssertNil(AgentSessionResolver.claudeUsage(fromJSONLData: Data()))
    }

    func testClaudeUsageAccumulatesCacheTokensAsInput() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":50,"cache_creation_input_tokens":100,"cache_read_input_tokens":20,"output_tokens":30}}}
        """
        let data = Data(jsonl.utf8)
        let usage = AgentSessionResolver.claudeUsage(fromJSONLData: data)
        XCTAssertEqual(usage?.tokensInput, 50)
        XCTAssertEqual(usage?.tokensOutput, 30)
    }

    // MARK: - Session usage dispatch

    func testSessionUsageReturnsNilForUnsupportedProviders() {
        XCTAssertNil(AgentSessionResolver.sessionUsage(provider: .codex, command: "", cwd: nil))
        XCTAssertNil(AgentSessionResolver.sessionUsage(provider: .grok, command: "", cwd: nil))
        XCTAssertNil(AgentSessionResolver.sessionUsage(provider: .copilot, command: "", cwd: nil))
        XCTAssertNil(AgentSessionResolver.sessionUsage(provider: .gemini, command: "", cwd: nil))
    }
}
