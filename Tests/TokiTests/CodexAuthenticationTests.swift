import Foundation
import XCTest
@testable import Toki

final class CodexAuthenticationTests: XCTestCase {
    private final class FakeSession: CodexAppServerSession, @unchecked Sendable {
        struct Request {
            let id: Int
            let method: String
            let params: String
        }

        var requests: [Request] = []
        var responses: (Request) -> CodexRPCResponse
        var closed = false

        init(responses: @escaping (Request) -> CodexRPCResponse) {
            self.responses = responses
        }

        func request(id: Int, method: String, params: String, timeout: TimeInterval) throws -> CodexRPCResponse {
            let request = Request(id: id, method: method, params: params)
            requests.append(request)
            return responses(request)
        }

        func close() {
            closed = true
        }
    }

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

    func testSnapshotCarriesTheAppServerIdentity() throws {
        let account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        var payload = CodexAppServerPayload()
        payload.rateLimits = ["rateLimits": ["primary": ["usedPercent": 25.0]]]
        payload.account = [
            "account": ["type": "chatgpt", "email": "person@example.com"],
            "workspaceRouting": ["chatgptAccountId": "workspace-1"]
        ]

        let snapshot = try CodexUsageClient(account: account).snapshot(from: payload)

        XCTAssertEqual(snapshot.codexIdentity, "person@example.com|workspace-1")
    }

    func testDuplicateCodexIdentityBlocksBothAccountsAndAValidRefreshRecovers() {
        let duplicate = [
            usageSnapshot(id: "work", name: "Work", identity: "person@example.com", remaining: 0.1),
            usageSnapshot(id: "personal", name: "Personal", identity: "person@example.com", remaining: 0.9)
        ]

        let blocked = UsageFetcher.reconcileCodexSnapshots(duplicate)

        XCTAssertEqual(blocked.map(\.isError), [true, true])
        XCTAssertTrue(blocked.allSatisfy { $0.resetCreditsAvailable == 0 })
        XCTAssertTrue(blocked.allSatisfy { $0.subtitle.contains("configuration error") })
        XCTAssertEqual(blocked.map(\.remainingRatio), [0.1, 0.9])

        let recovered = UsageFetcher.reconcileCodexSnapshots([
            usageSnapshot(id: "work", name: "Work", identity: "person@example.com|work", remaining: 0.1),
            usageSnapshot(id: "personal", name: "Personal", identity: "person@example.com|personal", remaining: 0.9)
        ])

        XCTAssertFalse(recovered.contains(where: \.isError))
        XCTAssertEqual(recovered.map(\.resetCreditsAvailable), [1, 1])
    }

    func testResetPreflightUsesLiveIdentityBeforeConsume() async {
        let session = FakeSession { _ in
            CodexRPCResponse(result: [
                "account": ["type": "chatgpt", "email": "other@example.com"]
            ], error: nil)
        }

        do {
            _ = try await CodexAppServerClient.consumeRateLimitResetCredit(
                account: AccountConfig(id: "work", name: "Work", provider: .codex),
                expectedIdentity: "person@example.com",
                creditID: nil,
                condition: nil,
                sessionFactory: { _, _ in session },
                binaryOverride: .pathInstall("/fixture/codex")
            )
            XCTFail("expected identity mismatch")
        } catch is ResetNotAttempted {
            XCTAssertEqual(session.requests.map(\.method), ["account/read"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testResetUsesOneSessionAndOneIdempotencyKeyAcrossRetries() async throws {
        var session: FakeSession!
        session = FakeSession { request in
            switch request.method {
            case "account/read":
                return CodexRPCResponse(result: ["account": ["type": "chatgpt", "email": "person@example.com"]], error: nil)
            case "account/rateLimits/read":
                return CodexRPCResponse(result: [
                    "rateLimitResetCredits": ["availableCount": 1],
                    "rateLimits": ["primary": ["usedPercent": 90.0]]
                ], error: nil)
            case "account/rateLimitResetCredit/consume":
                let outcome: Any = session.requests.filter { $0.method == request.method }.count == 1
                    ? NSNull()
                    : ["outcome": "reset"]
                return CodexRPCResponse(result: outcome, error: nil)
            default:
                return CodexRPCResponse(result: nil, error: ["message": "unexpected request"])
            }
        }

        let redeemed = try await CodexAppServerClient.consumeRateLimitResetCredit(
            account: AccountConfig(id: "work", name: "Work", provider: .codex),
            expectedIdentity: "person@example.com",
            creditID: nil,
            condition: nil,
            sessionFactory: { _, _ in session },
            binaryOverride: .pathInstall("/fixture/codex")
        )

        let consumes = session.requests.filter { $0.method == "account/rateLimitResetCredit/consume" }
        XCTAssertEqual(redeemed.outcome, "reset")
        XCTAssertEqual(session.requests.map { $0.method }, [
            "account/read", "account/rateLimits/read", "account/rateLimitResetCredit/consume",
            "account/read", "account/rateLimitResetCredit/consume"
        ])
        XCTAssertEqual(consumes.count, 2)
        let firstKey = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(consumes[0].params.utf8)) as? [String: Any]) ["idempotencyKey"] as? String
        let secondKey = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(consumes[1].params.utf8)) as? [String: Any]) ["idempotencyKey"] as? String
        XCTAssertEqual(firstKey, secondKey)
        XCTAssertTrue(session.closed)
    }

    func testIdentityChangeAfterAmbiguousConsumeIsNotResetNotAttempted() async {
        var session: FakeSession!
        session = FakeSession { request in
            switch request.method {
            case "account/read":
                let email = session.requests.filter { $0.method == request.method }.count == 1 ? "person@example.com" : "other@example.com"
                return CodexRPCResponse(result: ["account": ["type": "chatgpt", "email": email]], error: nil)
            case "account/rateLimits/read":
                return CodexRPCResponse(result: ["rateLimitResetCredits": ["availableCount": 1]], error: nil)
            case "account/rateLimitResetCredit/consume":
                return CodexRPCResponse(result: nil, error: ["message": "request timed out"])
            default:
                return CodexRPCResponse(result: nil, error: ["message": "unexpected request"])
            }
        }

        do {
            _ = try await CodexAppServerClient.consumeRateLimitResetCredit(
                account: AccountConfig(id: "work", name: "Work", provider: .codex),
                expectedIdentity: "person@example.com",
                creditID: nil,
                condition: nil,
                sessionFactory: { _, _ in session },
                binaryOverride: .pathInstall("/fixture/codex")
            )
            XCTFail("expected ambiguous failure")
        } catch is ResetNotAttempted {
            XCTFail("an attempted consume must remain conservative")
        } catch {
            XCTAssertEqual(session.requests.filter { $0.method == "account/rateLimitResetCredit/consume" }.count, 1)
        }
    }

    func testProductionSessionKeepsOnePIDAndTheConfiguredHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fixture = directory.appendingPathComponent("codex-fixture")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
            printf '%s|%s|%s\\n' "$$" "$CODEX_HOME" "$line" >> "$CODEX_HOME/session.log"
            case "$line" in
                *'\"id\":1,'*) printf '%s\\n' '{\"id\":1,\"result\":{}}' ;;
                *'\"method\":\"account/read\"'*) printf '%s\\n' '{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"person@example.com\"}}}' ;;
                *'\"method\":\"account/rateLimits/read\"'*) printf '%s\\n' '{\"id\":3,\"result\":{\"rateLimitResetCredits\":{\"availableCount\":1}}}' ;;
                *'\"method\":\"account/rateLimitResetCredit/consume\"'*) printf '%s\\n' '{\"id\":11,\"result\":{\"outcome\":\"reset\"}}' ;;
            esac
        done
        """
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var account = AccountConfig(id: "work", name: "Work", provider: .codex)
        account.codexAuthPath = home.appendingPathComponent("auth.json").path
        let redeemed = try await CodexAppServerClient.consumeRateLimitResetCredit(
            account: account,
            expectedIdentity: "person@example.com",
            creditID: nil,
            condition: nil,
            binaryOverride: .pathInstall(fixture.path)
        )

        let log = try String(contentsOf: home.appendingPathComponent("session.log"), encoding: .utf8)
        let fields = log.split(whereSeparator: \.isNewline).map { $0.split(separator: "|", maxSplits: 2) }
        XCTAssertEqual(redeemed.outcome, "reset")
        XCTAssertEqual(Set(fields.compactMap { $0.first }), Set([fields.first!.first!]))
        XCTAssertEqual(Set(fields.compactMap { $0.dropFirst().first.map(String.init) }), Set([home.path]))
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

    func testRecoveryRefreshesThenRetriesOnce() throws {
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

        _ = try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), transport: transport)
        XCTAssertEqual(methods, [
            "account/usage/read,account/rateLimits/read,account/read",
            "account/read",
            "account/usage/read,account/rateLimits/read,account/read"
        ])
        XCTAssertThrowsError(try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), transport: transport))
        XCTAssertEqual(methods.count, 5)
        XCTAssertEqual(timeouts, [20, 30, 20, 20, 20])
    }

    func testRecoveryRequiresSignedInAccountAndBackend401() throws {
        let account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        let prefix = "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: "
        for (code, message, signedIn) in [
            (-32600, "codex account authentication required to read rate limits", true),
            (-32603, prefix + "403 Forbidden", true),
            (-32603, prefix + "429 Too Many Requests", true),
            (-32603, "failed to fetch codex rate limits: request timed out", true),
            (-32603, prefix + "401 Unauthorized", false)
        ] {
            var calls = 0
            let transport: CodexAppServerClient.Transport = { _, _, _, _, _ in
                calls += 1
                let accountInfo: Any = signedIn ? ["type": "chatgpt"] as Any : NSNull()
                return ([4: ["account": accountInfo]], [], [3: ["code": code, "message": message]])
            }
            XCTAssertThrowsError(try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), transport: transport))
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
            XCTAssertThrowsError(try CodexAppServerClient.fetch(account: account, binary: .pathInstall("/usr/bin/codex"), transport: transport))
            XCTAssertEqual(calls, expectedCalls)
        }
    }

    private func usageSnapshot(id: String, name: String, identity: String, remaining: Double) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: name,
            provider: .codex,
            codexIdentity: identity,
            primary: "Usage",
            subtitle: "Codex",
            remainingRatio: remaining,
            resetCreditsAvailable: 1,
            metrics: []
        )
    }

}
