import Foundation
import XCTest
@testable import Toki

/// What a user actually sees when a provider is down: the card asks the store what to draw, and
/// the Events tab reads what was recorded. These drive that path with a real `UsageStore`, from a
/// downed status page through to the text on screen.
@MainActor
final class ServiceStatusDownTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-service-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("TOKI_STATE", directory.appendingPathComponent("state.json").path, 1)
        setenv("TOKI_CONFIG", directory.appendingPathComponent("config.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TOKI_STATE")
        unsetenv("TOKI_CONFIG")
        try? FileManager.default.removeItem(at: directory)
    }

    private let downPage = """
    {
      "status": {"indicator": "major", "description": "Partial System Outage"},
      "components": [
        {"name": "claude.ai", "status": "operational"},
        {"name": "Claude API (api.anthropic.com)", "status": "degraded_performance"},
        {"name": "Claude Code", "status": "major_outage"}
      ]
    }
    """

    private func parse(_ json: String, source: ServiceStatusSource, at date: Date) throws -> [Provider: ServiceStatus] {
        let payload = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return ServiceStatusClient.parse(summary: payload, source: source, checkedAt: date)
    }

    func testADownProviderIsWhatTheCardAsksForAndAnOperationalOneIsNot() throws {
        let now = Date()
        let store = UsageStore()
        let statuses = try parse(downPage, source: .claude, at: now)

        store.applyServiceStatuses(statuses, tracked: [.claudeCode, .claude, .anthropic], at: now)

        // What the card draws its dot from, and the words it puts beside it.
        let shown = try XCTUnwrap(store.disruptedServiceStatus(for: .claudeCode, now: now))
        XCTAssertEqual(shown.headline, "Claude Code is down")
        XCTAssertEqual(shown.detail, "Claude Code")
        XCTAssertEqual(shown.level, .majorOutage)
        XCTAssertEqual(shown.pageURL.absoluteString, "https://status.claude.com")

        // Degraded is still worth a dot, in its own words.
        let api = try XCTUnwrap(store.disruptedServiceStatus(for: .anthropic, now: now))
        XCTAssertEqual(api.headline, "Anthropic is degraded")

        // claude.ai is fine on the same page, so its card stays quiet even though the page as a
        // whole reads "major".
        XCTAssertNil(store.disruptedServiceStatus(for: .claude, now: now))
        // A provider that was never checked draws nothing at all.
        XCTAssertNil(store.disruptedServiceStatus(for: .codex, now: now))
        withExtendedLifetime(store) {}
    }

    func testGoingDownAndComingBackAreBothRecordedInEvents() throws {
        let wentDown = Date()
        let cameBack = wentDown.addingTimeInterval(20 * 60)
        let store = UsageStore()
        let tracked: Set<Provider> = [.claudeCode, .claude, .anthropic]

        store.applyServiceStatuses(try parse(downPage, source: .claude, at: wentDown), tracked: tracked, at: wentDown)

        let outage = try XCTUnwrap(store.events.first { $0.title == "Claude Code is down" })
        XCTAssertEqual(outage.kind, .serviceStatus)
        XCTAssertEqual(outage.detail, "Claude Code (status.claude.com)")
        XCTAssertFalse(outage.deliveredNotification, "an outage is recorded, never pushed as a notification")

        let healthy = """
        {
          "status": {"indicator": "none", "description": "All Systems Operational"},
          "components": [
            {"name": "claude.ai", "status": "operational"},
            {"name": "Claude API (api.anthropic.com)", "status": "operational"},
            {"name": "Claude Code", "status": "operational"}
          ]
        }
        """
        store.applyServiceStatuses(try parse(healthy, source: .claude, at: cameBack), tracked: tracked, at: cameBack)

        XCTAssertNil(store.disruptedServiceStatus(for: .claudeCode, now: cameBack), "the dot goes away")
        let recovery = try XCTUnwrap(store.events.first { $0.title == "Claude Code is back up" })
        XCTAssertEqual(recovery.kind, .recovered)
        XCTAssertEqual(recovery.detail, "All Systems Operational (status.claude.com)")
        withExtendedLifetime(store) {}
    }

    func testAnOutageThatHasNotChangedIsNotRecordedAgainOnEveryCheck() throws {
        let first = Date()
        let store = UsageStore()
        let tracked: Set<Provider> = [.claudeCode, .claude, .anthropic]

        for minutes in [0, 5, 10] {
            let at = first.addingTimeInterval(TimeInterval(minutes * 60))
            store.applyServiceStatuses(try parse(downPage, source: .claude, at: at), tracked: tracked, at: at)
        }

        XCTAssertEqual(store.events.filter { $0.title == "Claude Code is down" }.count, 1)
        withExtendedLifetime(store) {}
    }

    func testAWorseningOutageIsRecordedAgainBecauseTheCardNowSaysSomethingElse() throws {
        let first = Date()
        let later = first.addingTimeInterval(5 * 60)
        let store = UsageStore()
        let tracked: Set<Provider> = [.codex]
        let source = ServiceStatusSource.openai

        let degraded = #"{"status": {"indicator": "minor", "description": "Degraded"}, "components": [{"name": "Codex API", "status": "degraded_performance"}]}"#
        let down = #"{"status": {"indicator": "critical", "description": "Major Outage"}, "components": [{"name": "Codex API", "status": "major_outage"}]}"#

        store.applyServiceStatuses(try parse(degraded, source: source, at: first), tracked: tracked, at: first)
        store.applyServiceStatuses(try parse(down, source: source, at: later), tracked: tracked, at: later)

        XCTAssertEqual(store.events.filter { $0.kind == .serviceStatus }.map(\.title), [
            "Codex is down",
            "Codex is degraded"
        ], "newest first, and the worsening is its own entry")
        XCTAssertEqual(store.disruptedServiceStatus(for: .codex, now: later)?.level, .majorOutage)
        withExtendedLifetime(store) {}
    }

    func testAPageThatFailsToAnswerLeavesAKnownOutageOnScreen() throws {
        let wentDown = Date()
        let nextCheck = wentDown.addingTimeInterval(5 * 60)
        let store = UsageStore()
        let tracked: Set<Provider> = [.claudeCode, .codex]

        store.applyServiceStatuses(try parse(downPage, source: .claude, at: wentDown), tracked: tracked, at: wentDown)

        // Claude's page is unreachable this round while OpenAI's answers: a missing provider means
        // "not asked", so the outage that is still happening keeps its dot.
        let codexOnly = try parse(
            #"{"status": {"indicator": "none", "description": "All Systems Operational"}, "components": [{"name": "Codex API", "status": "operational"}]}"#,
            source: .openai,
            at: nextCheck
        )
        store.applyServiceStatuses(codexOnly, tracked: tracked, at: nextCheck)

        XCTAssertEqual(store.disruptedServiceStatus(for: .claudeCode, now: nextCheck)?.headline, "Claude Code is down")
        XCTAssertEqual(store.events.filter { $0.title == "Claude Code is back up" }.count, 0, "silence is not a recovery")
        withExtendedLifetime(store) {}
    }

    func testAnAnswerNobodyCouldConfirmForHalfAnHourStopsBeingShown() throws {
        let wentDown = Date()
        let store = UsageStore()

        store.applyServiceStatuses(try parse(downPage, source: .claude, at: wentDown), tracked: [.claudeCode], at: wentDown)

        XCTAssertNotNil(store.disruptedServiceStatus(for: .claudeCode, now: wentDown.addingTimeInterval(29 * 60)))
        XCTAssertNil(
            store.disruptedServiceStatus(for: .claudeCode, now: wentDown.addingTimeInterval(31 * 60)),
            "past the staleness bound Toki no longer knows, and says nothing rather than guessing"
        )

        // The same bound drops it from the merge, so it cannot come back on a later round either.
        let laterCheck = wentDown.addingTimeInterval(45 * 60)
        store.applyServiceStatuses([:], tracked: [.claudeCode], at: laterCheck)
        XCTAssertNil(store.serviceStatuses[.claudeCode])
        withExtendedLifetime(store) {}
    }

    func testEveryDisruptedLevelReadsAsASentenceOnTheCard() {
        let headlines = [ServiceStatusLevel.degraded, .partialOutage, .majorOutage, .maintenance].map { level in
            ServiceStatus(
                provider: .codex,
                level: level,
                pageDescription: "",
                affectedComponents: [],
                pageURL: URL(string: "https://status.openai.com")!,
                checkedAt: Date()
            ).headline
        }

        XCTAssertEqual(headlines, [
            "Codex is degraded",
            "Codex is partly down",
            "Codex is down",
            "Codex is under maintenance"
        ])
    }
}
