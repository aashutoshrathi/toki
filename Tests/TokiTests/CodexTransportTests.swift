import XCTest
@testable import Toki

final class CodexTransportTests: XCTestCase {
    func testProcessExpandsHomeInSearchPath() throws {
        let (account, binary, directory) = try fixture(#"""
        printf '%s' "$PATH" > "$CODEX_HOME/path.txt"
        while IFS= read -r line; do
            case "$line" in
                *'"id":1,'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            esac
        done
        """#)
        let session = try CodexAppServerProcessSession(account: account, binary: binary, path: agentCommandSearchPath)
        defer { session.close() }

        let actualPath = try String(contentsOf: directory.appendingPathComponent("path.txt"), encoding: .utf8)
        let expanded = agentCommandSearchPath.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        XCTAssertTrue(actualPath.hasPrefix(expanded + ":"))
        XCTAssertFalse(actualPath.contains("$HOME"))
    }

    func testCloseKillsAProcessThatIgnoresTermination() throws {
        let (account, binary, _) = try fixture(#"""
        trap '' TERM
        IFS= read -r line
        printf '%s\n' '{"id":1,"result":{}}'
        while :; do :; done
        """#)
        let session = try CodexAppServerProcessSession(account: account, binary: binary, path: "/usr/bin:/bin")
        let start = ProcessInfo.processInfo.systemUptime

        session.close()

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertThrowsError(try session.request(id: 2, method: "account/read", params: "null", timeout: 1))
        session.close()
    }

    func testBannerLinesDoNotAbortRPCResponses() throws {
        let (account, binary, _) = try fixture(#"""
        while IFS= read -r line; do
            printf '%s\n' 'Codex fixture banner'
            case "$line" in
                *'"id":1,'*) printf '%s\n' '{"id":1,"result":{}}' ;;
                *'"id":2,'*) printf '%s\n' '{"id":2,"result":{"account":{"email":"fixture@example.com"}}}' ;;
            esac
        done
        """#)
        let session = try CodexAppServerProcessSession(account: account, binary: binary, path: "/usr/bin:/bin")
        defer { session.close() }

        let response = try session.request(id: 2, method: "account/read", params: "null", timeout: 1)

        XCTAssertEqual(CodexAccountInfo.email(from: response.result), "fixture@example.com")
    }

    func testRejectedInitializationPreventsAllFurtherRequests() async throws {
        let (account, binary, directory) = try fixture(#"""
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$CODEX_HOME/requests.log"
            printf '%s\n' '{"id":1,"error":{"code":-32600,"message":"unsupported capability"}}'
        done
        """#)

        do {
            _ = try await CodexAppServerClient.consumeRateLimitResetCredit(
                account: account,
                expectedIdentity: "fixture@example.com",
                creditID: nil,
                condition: nil,
                binaryOverride: binary
            )
            XCTFail("Expected initialization rejection")
        } catch let error as ResetNotAttempted {
            XCTAssertEqual(error.localizedDescription, "unsupported capability")
        }

        let log = try String(contentsOf: directory.appendingPathComponent("requests.log"), encoding: .utf8)
        let lines = log.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("\"method\":\"initialize\"") == true)
    }

    private func fixture(_ body: String) throws -> (AccountConfig, CodexBinary, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-fixture")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var account = AccountConfig(id: "fixture", name: "Fixture", provider: .codex)
        account.codexAuthPath = directory.appendingPathComponent("auth.json").path
        return (account, .pathInstall(executable.path), directory)
    }
}
