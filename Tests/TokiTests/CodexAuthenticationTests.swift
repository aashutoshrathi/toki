import Foundation
import XCTest
@testable import Toki

final class CodexAuthenticationTests: XCTestCase {
    func testDefaultCodexHomeDoesNotDependOnAuthFileExistence() {
        let account = AccountConfig(id: "codex", name: "Codex", provider: .codex)

        XCTAssertEqual(
            CodexAppServerClient.codexHomeDirectory(for: account),
            (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        )
    }

    func testCustomAuthPathSelectsItsContainingCodexHome() {
        var account = AccountConfig(id: "work", name: "Work Codex", provider: .codex)
        account.codexAuthPath = "~/codex-work/auth.json"

        XCTAssertEqual(
            CodexAppServerClient.codexHomeDirectory(for: account),
            (NSHomeDirectory() as NSString).appendingPathComponent("codex-work")
        )
    }

    func testAccountPayloadRecognizesAKeyringBackedSignIn() {
        let payload: [String: Any] = [
            "account": [
                "type": "chatgpt",
                "planType": "pro",
                "email": "person@example.com"
            ]
        ]

        XCTAssertTrue(CodexAccountInfo.isSignedIn(payload))
        XCTAssertEqual(CodexAccountInfo.email(from: payload), "person@example.com")
    }

    func testAccountPayloadRejectsASignedOutSession() {
        let payload: [String: Any] = ["account": NSNull()]

        XCTAssertFalse(CodexAccountInfo.isSignedIn(payload))
        XCTAssertNil(CodexAccountInfo.email(from: payload))
    }

    func testSnapshotUsesAppServerAccountWithoutReadingConfiguredAuthFile() throws {
        var account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        account.codexAuthPath = "~/.codex/definitely-not-here.json"
        var payload = CodexAppServerPayload()
        payload.rateLimits = [
            "rateLimits": [
                "primary": ["usedPercent": 25.0, "windowDurationMins": 300.0]
            ]
        ]
        payload.account = [
            "account": ["type": "chatgpt", "email": "person@example.com"]
        ]

        let snapshot = try CodexUsageClient(account: account).snapshot(from: payload)

        XCTAssertEqual(snapshot.primary, "75% left")
        XCTAssertEqual(snapshot.displayProgressRatio, 0.75)
        XCTAssertEqual(snapshot.metrics.first?.group, .quota)
        XCTAssertEqual(snapshot.metrics.first?.value, "75% left")
        XCTAssertTrue(snapshot.accountInfo.contains {
            $0.label == "Email" && $0.value == "person@example.com"
        })
        XCTAssertFalse(snapshot.accountInfo.contains { $0.label == "Source" })
    }
    func testHistoricalUsageDoesNotBecomeTodaysReading() {
        let usage = CodexUsage(json: [
            "daily_usage_buckets": [["start_date": "2000-01-01", "tokens": 300]],
            "summary": ["lifetime_tokens": 300]
        ])
        XCTAssertNil(usage.todayTokens)
        XCTAssertFalse(usage.metrics.contains { $0.label == "Today" })
        XCTAssertEqual(usage.metrics.first?.group, .activity)
        XCTAssertEqual(usage.metrics.first?.label, "Latest day")
        XCTAssertTrue(usage.metrics.first?.value.contains("2000-01-01") == true)
    }

    func testSpendingProgressKeepsItsExistingDirection() {
        var snapshot = AccountSnapshot(id: "cursor", name: "Cursor", provider: .cursor,
                                       primary: "", subtitle: "", remainingRatio: 0.75, metrics: [])
        XCTAssertEqual(snapshot.displayProgressRatio, 0.25)
        snapshot.progressRatio = 0.4
        XCTAssertEqual(snapshot.displayProgressRatio, 0.4)
    }

}
