import Foundation
import XCTest
@testable import Toki

final class ServiceStatusTests: XCTestCase {
    private let checkedAt = ISO8601DateFormatter().date(from: "2026-09-03T12:00:00Z")!

    private func parse(_ json: String, source: ServiceStatusSource) throws -> [Provider: ServiceStatus] {
        let payload = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return ServiceStatusClient.parse(summary: payload, source: source, checkedAt: checkedAt)
    }

    // Component names as status.claude.com publishes them.
    private func claudePage(claudeCode: String, claudeAI: String = "operational", api: String = "operational", indicator: String = "none", description: String = "All Systems Operational") -> String {
        """
        {
          "page": {"name": "Claude", "url": "https://status.claude.com"},
          "status": {"indicator": "\(indicator)", "description": "\(description)"},
          "components": [
            {"name": "claude.ai", "status": "\(claudeAI)"},
            {"name": "Claude Console (platform.claude.com)", "status": "operational"},
            {"name": "Claude API (api.anthropic.com)", "status": "\(api)"},
            {"name": "Claude Code", "status": "\(claudeCode)"}
          ]
        }
        """
    }

    func testProviderTakesItsOwnComponentNotTheWholePageRollUp() throws {
        // The page reads "major" because something else on it is down; Claude Code itself is fine
        // and must not be reported as down for it.
        let statuses = try parse(
            claudePage(claudeCode: "operational", claudeAI: "major_outage", indicator: "major", description: "Partial System Outage"),
            source: .claude
        )

        XCTAssertEqual(statuses[.claudeCode]?.level, .operational)
        XCTAssertEqual(statuses[.claudeCode]?.affectedComponents, [])
        XCTAssertEqual(statuses[.claude]?.level, .majorOutage)
        XCTAssertEqual(statuses[.claude]?.affectedComponents, ["claude.ai"])
        XCTAssertEqual(statuses[.anthropic]?.level, .operational)
    }

    func testDisruptedComponentIsNamedAndCarriesThePageURL() throws {
        let statuses = try parse(
            claudePage(claudeCode: "degraded_performance", indicator: "minor", description: "Degraded Performance"),
            source: .claude
        )

        let status = try XCTUnwrap(statuses[.claudeCode])
        XCTAssertEqual(status.level, .degraded)
        XCTAssertTrue(status.level.isDisrupted)
        XCTAssertEqual(status.detail, "Claude Code")
        XCTAssertEqual(status.pageURL.absoluteString, "https://status.claude.com")
        XCTAssertEqual(status.checkedAt, checkedAt)
    }

    func testOperationalProviderFallsBackToThePageWordingForItsDetail() throws {
        let statuses = try parse(claudePage(claudeCode: "operational"), source: .claude)

        let status = try XCTUnwrap(statuses[.claudeCode])
        XCTAssertFalse(status.level.isDisrupted)
        XCTAssertEqual(status.detail, "All Systems Operational")
    }

    // Component names as status.openai.com publishes them.
    private func openAIPage(codexAPI: String, codexWeb: String = "operational", chatCompletions: String = "operational", indicator: String = "none") -> String {
        """
        {
          "page": {"name": "OpenAI", "url": "https://status.openai.com/"},
          "status": {"indicator": "\(indicator)", "description": "Status"},
          "components": [
            {"name": "Codex API", "status": "\(codexAPI)"},
            {"name": "Codex Web", "status": "\(codexWeb)"},
            {"name": "Codex in ChatGPT Desktop", "status": "operational"},
            {"name": "Chat Completions", "status": "\(chatCompletions)"},
            {"name": "Sora", "status": "major_outage"}
          ]
        }
        """
    }

    func testOneProviderSpansEveryComponentOfItsFamilyAndTakesTheWorst() throws {
        let statuses = try parse(
            openAIPage(codexAPI: "degraded_performance", codexWeb: "major_outage"),
            source: .openai
        )

        let codex = try XCTUnwrap(statuses[.codex])
        XCTAssertEqual(codex.level, .majorOutage)
        // Most severe first, and only the components that are actually disrupted.
        XCTAssertEqual(codex.affectedComponents, ["Codex Web", "Codex API"])
        // Sora being down belongs to neither Codex nor the API surface Toki reads.
        XCTAssertEqual(statuses[.openai]?.level, .operational)
    }

    func testProviderWithNoComponentOfItsOwnUsesThePageRollUp() throws {
        let statuses = try parse(openAIPage(codexAPI: "operational", indicator: "critical"), source: .openai)

        let chatgpt = try XCTUnwrap(statuses[.chatgpt])
        XCTAssertEqual(chatgpt.level, .majorOutage)
        XCTAssertEqual(chatgpt.affectedComponents, [])
        // A provider that does have components is unaffected by the roll-up.
        XCTAssertEqual(statuses[.codex]?.level, .operational)
    }

    func testMaintenanceLosesToARealFaultOnAnotherComponent() throws {
        let statuses = try parse(
            openAIPage(codexAPI: "under_maintenance", codexWeb: "partial_outage"),
            source: .openai
        )

        XCTAssertEqual(statuses[.codex]?.level, .partialOutage)
        XCTAssertLessThan(ServiceStatusLevel.maintenance, ServiceStatusLevel.degraded)
        XCTAssertLessThan(ServiceStatusLevel.partialOutage, ServiceStatusLevel.majorOutage)
    }

    func testUnknownComponentStateFallsBackToThePageRollUpRatherThanReportingHealthy() throws {
        let json = """
        {
          "status": {"indicator": "major", "description": "Partial System Outage"},
          "components": [{"name": "Claude Code", "status": "something_new"}]
        }
        """

        let statuses = try parse(json, source: .claude)

        XCTAssertEqual(statuses[.claudeCode]?.level, .partialOutage)
    }

    func testPayloadWithNothingUsableYieldsNoStatuses() throws {
        XCTAssertTrue(try parse("{}", source: .claude).isEmpty)
        XCTAssertTrue(try parse("[]", source: .claude).isEmpty)
        XCTAssertTrue(try parse(#"{"components": [{"name": "Claude Code"}]}"#, source: .claude).isEmpty)
    }

    func testOnlyThePagesCoveringTrackedProvidersAreCalled() {
        let claudeOnly = ServiceStatusSource.sources(covering: [.claudeCode])
        XCTAssertEqual(claudeOnly.map(\.id), ["claude"])

        let mixed = ServiceStatusSource.sources(covering: [.claudeCode, .codex, .openCode])
        XCTAssertEqual(Set(mixed.map(\.id)), ["claude", "openai"])

        // Providers that publish no status page Toki reads cost no request at all.
        XCTAssertTrue(ServiceStatusSource.sources(covering: [.openCode, .pi, .manual]).isEmpty)
    }

    func testEverySourceAsksItsPageForTheStatuspageSummary() {
        XCTAssertEqual(
            ServiceStatusSource.claude.summaryURL.absoluteString,
            "https://status.claude.com/api/v2/summary.json"
        )
        for source in ServiceStatusSource.all {
            XCTAssertTrue(source.summaryURL.absoluteString.hasSuffix("/api/v2/summary.json"), source.id)
        }
    }
}
