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

    func testHistoricalUsageDoesNotBecomeTodaysReading() {
        let usage = CodexUsage(json: [
            "daily_usage_buckets": [["start_date": "2000-01-01", "tokens": 300]],
            "summary": ["lifetime_tokens": 300]
        ])
        XCTAssertNil(usage.todayTokens)
        XCTAssertFalse(usage.metrics.contains { $0.label == "Today" })
        XCTAssertEqual(usage.metrics.first?.label, "Latest day")
        XCTAssertTrue(usage.metrics.first?.value.contains("2000-01-01") == true)
    }

    func testManualRecoveryRefreshesThenRetriesOnce() throws {
        var account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        account.codexAuthPath = "/tmp/toki-recovery-\(UUID().uuidString)/auth.json"
        var methods: [String] = []
        var timeouts: [Int] = []
        let unauthorized: [String: Any] = [
            "code": -32603,
            "message": "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"
        ]
        let transport: CodexAppServerClient.Transport = { _, _, requests, _, timeout in
            methods.append(requests.map(\.method).joined(separator: ","))
            timeouts.append(timeout)
            if requests.first?.params == #"{"refreshToken":true}"# {
                return ([2: ["account": ["type": "chatgpt"]]], [], [:])
            }
            let accountResult: [String: Any] = ["account": ["type": "chatgpt"]]
            if methods.count != 3 {
                return ([4: accountResult], [], [3: unauthorized])
            }
            return ([3: ["rateLimits": [:]], 4: accountResult], [], [:])
        }

        _ = try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), allowsAuthRecovery: true, transport: transport)
        XCTAssertEqual(methods, [
            "account/usage/read,account/rateLimits/read,account/read",
            "account/read",
            "account/usage/read,account/rateLimits/read,account/read"
        ])
        XCTAssertThrowsError(try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), allowsAuthRecovery: true, transport: transport))
        XCTAssertEqual(methods.count, 5)
        XCTAssertEqual(timeouts, [20, 30, 20, 20, 20])
    }

    func testRecoveryRequiresManualRefreshAndBackend401() throws {
        let account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        let error: [String: Any] = ["code": -32600, "message": "codex account authentication required to read rate limits"]
        XCTAssertFalse(CodexAppServerClient.isBackendUnauthorized(error))
        XCTAssertFalse(CodexAppServerClient.isBackendUnauthorized(["code": -32603, "message": "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 403 Forbidden"]))
        for enabled in [false, true] {
            var calls = 0
            let transport: CodexAppServerClient.Transport = { _, _, _, _, _ in
                calls += 1
                return ([4: ["account": ["type": "chatgpt"]]], [], [3: enabled ? error : ["code": -32603, "message": "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"]])
            }
            XCTAssertThrowsError(try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), allowsAuthRecovery: enabled, transport: transport))
            XCTAssertEqual(calls, 1)
        }
    }

    func testFailedRenewalDoesNotRetryUsage() {
        var account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        account.codexAuthPath = "/tmp/toki-recovery-\(UUID().uuidString)/auth.json"
        var calls = 0
        let transport: CodexAppServerClient.Transport = { _, _, requests, _, _ in
            calls += 1
            if requests.first?.params == #"{"refreshToken":true}"# {
                return ([:], [], [2: ["code": -32603, "message": "refresh failed"]])
            }
            return ([4: ["account": ["type": "chatgpt"]]], [], [3: ["code": -32603, "message": "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"]])
        }
        for expectedCalls in [2, 3] {
            XCTAssertThrowsError(try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), allowsAuthRecovery: true, transport: transport))
            XCTAssertEqual(calls, expectedCalls)
        }
    }

}
