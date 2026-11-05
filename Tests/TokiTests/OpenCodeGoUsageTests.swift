import XCTest
@testable import Toki

// OpenCode Go reports three concurrent allowances. The shape below is what the real
// `opencode api get /api/experimental/usage/limits` prints, wrapper included.
final class OpenCodeGoUsageTests: XCTestCase {
    private func payload(
        rolling: Any = ["percent": 37, "limited": false, "resetsAt": 1_793_878_767_000],
        weekly: Any = ["percent": 16, "limited": false, "resetsAt": 1_794_182_400_000],
        monthly: Any = ["percent": 13, "limited": false, "resetsAt": 1_795_946_700_000]
    ) -> [String: Any] {
        [
            "location": ["directory": "/Users/me"],
            "data": [
                "workspace": ["id": "org_1", "name": "Personal"],
                "go": ["rolling": rolling, "weekly": weekly, "monthly": monthly],
                "budgets": []
            ]
        ]
    }

    private func limits(_ json: [String: Any]) -> OpenCodeGoLimits {
        OpenCodeGoLimits(json: json)
    }

    private func localSnapshot() -> AccountSnapshot {
        AccountSnapshot(
            id: OpenCodeUsageClient.autoDetectedID,
            name: "OpenCode",
            provider: .openCode,
            primary: "$1.20 / 10K in / 2K out today",
            subtitle: "OpenCode - local usage",
            remainingRatio: nil,
            metrics: [
                MetricLine(label: "Today", value: "10K in / 2K out"),
                MetricLine(label: "Total", value: "$42.00"),
                MetricLine(label: "Sessions", value: "12")
            ],
            menuBarValue: "$1.20"
        )
    }

    func testReadsAllThreeWindowsAsRemainingPercent() {
        let parsed = limits(payload())
        XCTAssertEqual(parsed.windows.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(parsed.windowsAsRateLimits.map(\.percentLeft), [63, 84, 87])
        XCTAssertEqual(parsed.workspaceName, "Personal")
    }

    func testEachWindowCarriesItsResetAndPaceDuration() {
        let parsed = limits(payload())
        let windows = parsed.windowsAsRateLimits
        XCTAssertEqual(windows[0].duration, OpenCodeGoLimits.rollingDuration)
        XCTAssertEqual(windows[1].duration, OpenCodeGoLimits.weeklyDuration)
        XCTAssertEqual(windows[2].duration, OpenCodeGoLimits.monthlyDuration)
        XCTAssertNotNil(windows[0].resetAt, "a millisecond epoch has to survive as a real date")
        XCTAssertTrue(windows[0].resetHint?.hasPrefix("resets in ") == true)
    }

    func testALimitedWindowReadsAsFullySpent() {
        let parsed = limits(payload(rolling: ["percent": 100, "limited": true, "resetsAt": 1_793_878_767_000]))
        XCTAssertEqual(parsed.windowsAsRateLimits.first?.percentLeft, 0)
    }

    func testABarePayloadWithoutTheWrapperStillParses() {
        let parsed = limits([
            "go": ["rolling": ["percent": 20, "limited": false, "resetsAt": 1_793_878_767_000]]
        ])
        XCTAssertEqual(parsed.windows.map(\.label), ["5h"])
        XCTAssertEqual(parsed.windowsAsRateLimits.first?.percentLeft, 80)
    }

    // A BYO-key install has no go block at all: it must keep the local-spend card, not an
    // empty set of bars.
    func testAConsoleOnlyInstallReportsNoWindows() {
        let parsed = limits(["data": ["workspace": ["name": "Personal"], "budgets": []]])
        XCTAssertFalse(parsed.hasUsage)
        XCTAssertTrue(parsed.windowsAsRateLimits.isEmpty)
    }

    func testAFailedOrUnparseableResponseIsNotAnError() {
        XCTAssertNil(OpenCodeGoClient.parse(output: nil))
        XCTAssertNil(OpenCodeGoClient.parse(output: "not json"))
        XCTAssertNil(OpenCodeGoClient.parse(output: "{\"data\":{}}"))
    }

    func testMergeKeepsTodaysSpendAndAddsThePlanWindows() {
        let merged = OpenCodeUsageClient.merging(limits(payload()), into: localSnapshot())

        XCTAssertEqual(merged.subtitle, "OpenCode Go - Personal")
        XCTAssertEqual(merged.primary, "63% left", "the tightest window is the headline")
        XCTAssertEqual(merged.remainingRatio, 0.63)
        XCTAssertEqual(merged.allWindows.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(merged.extraWindows.map(\.label), ["30d"], "the third window is not dropped")
        XCTAssertEqual(
            merged.metrics.map(\.label),
            ["Today", "5h", "7d", "30d", "Total", "Sessions"],
            "window rows sit under today's spend, local totals stay put"
        )
        XCTAssertEqual(merged.metrics[0].value, "10K in / 2K out")
        XCTAssertTrue(merged.metrics[1].value.hasPrefix("37% used - resets in "), "got \(merged.metrics[1].value)")
    }

    func testMergeReportsAReachedLimit() {
        let merged = OpenCodeUsageClient.merging(
            limits(payload(monthly: ["percent": 100, "limited": true, "resetsAt": 1_795_946_700_000])),
            into: localSnapshot()
        )
        XCTAssertEqual(merged.primary, "0% left")
        XCTAssertEqual(merged.metrics.first { $0.label == "Limit" }?.value, "30d reached")
    }

    func testMergeWithoutWindowsLeavesTheLocalCardAlone() {
        let local = localSnapshot()
        let merged = OpenCodeUsageClient.merging(limits(["data": [:]]), into: local)
        XCTAssertEqual(merged, local)
    }

    func testResolverRejectsRelativeAndMissingPaths() {
        XCTAssertNil(try OpenCodeBinaryResolver.resolve(pathProbe: { nil }, isExecutable: { _ in true }))
        XCTAssertNil(try OpenCodeBinaryResolver.resolve(pathProbe: { "opencode" }, isExecutable: { _ in true }))
        XCTAssertNil(try OpenCodeBinaryResolver.resolve(pathProbe: { "/usr/local/bin/opencode" }, isExecutable: { _ in false }))
        XCTAssertEqual(
            try OpenCodeBinaryResolver.resolve(pathProbe: { "/opt/homebrew/bin/opencode\n" }, isExecutable: { _ in true }),
            "/opt/homebrew/bin/opencode"
        )
    }
}
