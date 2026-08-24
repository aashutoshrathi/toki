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
        XCTAssertTrue(snapshot.accountInfo.contains {
            $0.label == "Email" && $0.value == "person@example.com"
        })
        XCTAssertFalse(snapshot.accountInfo.contains { $0.label == "Source" })
    }
}
