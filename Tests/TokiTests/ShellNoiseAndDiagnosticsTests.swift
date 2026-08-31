import Foundation
import XCTest
@testable import Toki

final class ShellNoiseAndDiagnosticsTests: XCTestCase {
    // MARK: - Login-shell noise stripping

    func testProfileNoiseBeforeSentinelIsDiscarded() {
        let sentinel = "__TOKI_OUTPUT_TEST__"
        let output = "already linked: ears-add-requirements\n\(sentinel){\"claudeAiOauth\":{}}"
        XCTAssertEqual(
            SecretResolver.discardingLoginShellNoise(output, before: sentinel),
            "{\"claudeAiOauth\":{}}"
        )
    }

    func testOutputWithoutSentinelIsReturnedUnchanged() {
        let output = "plain output"
        XCTAssertEqual(
            SecretResolver.discardingLoginShellNoise(output, before: "__TOKI_OUTPUT_TEST__"),
            output
        )
    }

    func testMultilineNoiseIsDiscardedInFull() {
        let sentinel = "__TOKI_OUTPUT_TEST__"
        let output = "banner line one\nbanner line two\n\(sentinel)payload"
        XCTAssertEqual(SecretResolver.discardingLoginShellNoise(output, before: sentinel), "payload")
    }

    #if os(macOS)
    func testRunShellReturnsExactlyTheCommandsOutput() throws {
        // End to end through /bin/zsh -l: whatever the login profile on this machine prints
        // must not reach the caller.
        //
        // The timeout is raised well above the 15s production default because the two are
        // measuring different things. That default is tuned for a user waiting on a key fetch,
        // where giving up matters. Here the only claim under test is that profile noise is
        // stripped, and a cold CI runner's first `zsh -l` pays for path_helper and the rest of
        // /etc/zprofile all at once - which is what made this fail on a merge commit whose
        // code had already passed on the branch.
        XCTAssertEqual(try SecretResolver.runShell("printf 'hi'", timeout: 120), "hi")
    }
    #endif

    // MARK: - Claude credential parsing

    func testExtractAccessTokenFromValidCredentials() throws {
        let credentials = #"{"claudeAiOauth":{"accessToken":"token-123"}}"#
        XCTAssertEqual(try ClaudeCodeCredentialReader.extractAccessToken(from: credentials), "token-123")
    }

    func testPollutedCredentialsFailWithInvalidJSONMessage() {
        let credentials = "already linked: some-branch\n" + #"{"claudeAiOauth":{"accessToken":"token-123"}}"#
        XCTAssertThrowsError(try ClaudeCodeCredentialReader.extractAccessToken(from: credentials)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not valid JSON"), "got: \(error.localizedDescription)")
        }
    }

    func testCredentialsWithoutTokenSayWhatToDoAndWhatWasThere() {
        let credentials = #"{"claudeAiOauth":{"refreshToken":"r","expiresAt":1}}"#
        XCTAssertThrowsError(try ClaudeCodeCredentialReader.extractAccessToken(from: credentials)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("/login"), message)
            XCTAssertTrue(message.contains("expiresAt, refreshToken"), message)
        }
    }

    func testCredentialsWithoutOAuthSectionNameTheSectionAndTheKeysFound() {
        let credentials = #"{"apiKey":"sk-ant-x","someOther":1}"#
        XCTAssertThrowsError(try ClaudeCodeCredentialReader.extractAccessToken(from: credentials)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("claudeAiOauth"), message)
            XCTAssertTrue(message.contains("/login"), message)
            XCTAssertTrue(message.contains("apiKey, someOther"), message)
        }
    }

    func testCredentialErrorsNeverEchoTheSecretValues() {
        let credentials = #"{"apiKey":"sk-ant-super-secret","claudeAiOauthX":{}}"#
        XCTAssertThrowsError(try ClaudeCodeCredentialReader.extractAccessToken(from: credentials)) { error in
            XCTAssertFalse(error.localizedDescription.contains("sk-ant-super-secret"), error.localizedDescription)
        }
    }

    func testCredentialSearchCoversEveryKnownConfigLocation() {
        let candidates = ClaudeCodeCredentialReader.credentialFileCandidates(includeShellEnvironment: false)
        XCTAssertTrue(candidates.contains("~/.claude/.credentials.json"), "\(candidates)")
        XCTAssertTrue(candidates.contains("~/.config/claude/.credentials.json"), "\(candidates)")
        XCTAssertEqual(Set(candidates).count, candidates.count, "duplicate candidates: \(candidates)")
        for candidate in candidates {
            XCTAssertTrue(candidate.hasSuffix("/.credentials.json"), candidate)
            XCTAssertFalse(candidate.contains("//"), candidate)
        }
    }

    func testKeychainSearchFallsBackToAServiceOnlyLookup() {
        let accounts = ClaudeCodeCredentialReader.keychainAccountCandidates()
        XCTAssertTrue(accounts.contains(where: { $0 != nil }), "\(accounts)")
        XCTAssertEqual(accounts.last, .some(nil), "the service-only search must come last: \(accounts)")
    }

    func testDeniedKeychainPromptIsNotRetriedUnderEveryAccountName() {
        let missing = LocalizedErrorMessage("No Claude Code credentials found in your Keychain. Sign in to Claude Code, then refresh.")
        let denied = LocalizedErrorMessage("Couldn't read the Claude Code credentials from your Keychain: User canceled the operation.")
        XCTAssertTrue(ClaudeCodeCredentialReader.isMissingKeychainItem(missing))
        XCTAssertFalse(ClaudeCodeCredentialReader.isMissingKeychainItem(denied))
    }

    func testCredentialFileRejectsASymlinkStandingInForAnotherFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("elsewhere.json")
        try #"{"claudeAiOauth":{"accessToken":"planted"}}"#.write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(".credentials.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ClaudeCodeCredentialReader.readCredentialsFile(at: link.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a regular file"), error.localizedDescription)
        }
    }

    func testCredentialFileRejectsAWorldWritableFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent(".credentials.json")
        try #"{"claudeAiOauth":{"accessToken":"planted"}}"#.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path.path)

        XCTAssertThrowsError(try ClaudeCodeCredentialReader.readCredentialsFile(at: path.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("writable by other users"), error.localizedDescription)
        }
    }

    func testCredentialFileAcceptsAPrivateRegularFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent(".credentials.json")
        try #"{"claudeAiOauth":{"accessToken":"mine"}}"#.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        let bundle = try ClaudeCodeCredentialReader.readCredentialsFile(at: path.path)
        XCTAssertEqual(try ClaudeCodeCredentialReader.extractAccessToken(from: bundle.credentials), "mine")
    }

    func testRelativeOrControlCharacterConfigDirectoriesAreNotSearched() {
        for bad in ["relative/path", "", "\u{1}/tmp/evil", "/tmp/ev\nil"] {
            XCTAssertFalse(ClaudeCodeCredentialReader.isUsableConfigDirectory(bad), "accepted \(bad.debugDescription)")
        }
        for good in ["/opt/claude", "~/.claude", "~"] {
            XCTAssertTrue(ClaudeCodeCredentialReader.isUsableConfigDirectory(good), "rejected \(good)")
        }
    }

    func testAgentSearchPathCoversVersionManagerBinDirectories() {
        for directory in ["$HOME/.bun/bin", "$HOME/.volta/bin", "$HOME/.local/share/mise/shims", "/opt/homebrew/bin"] {
            XCTAssertTrue(agentCommandSearchPath.contains(directory), "missing \(directory)")
        }
        // Any stray `npm install` in the home directory creates this and fills it with whatever a
        // dependency shipped, so it must never become a place Toki looks for an agent binary.
        XCTAssertFalse(agentCommandSearchPath.contains("$HOME/node_modules"), agentCommandSearchPath)
    }

    func testCodexNotFoundMessageNamesBothInstalls() {
        let message = CodexBinaryResolver.notFoundMessage
        XCTAssertTrue(message.contains("Codex CLI"), message)
        XCTAssertTrue(message.contains("PATH"), message)
        XCTAssertTrue(message.contains("Codex macOS app"), message)
        // It must read as an actionable install hint, never a leaked raw shell line.
        XCTAssertFalse(message.contains("app-server"), message)
    }

    // MARK: - Diagnostic error detail

    func testNSErrorDetailCarriesDomainAndCode() {
        do {
            _ = try JSONSerialization.jsonObject(with: Data("not json".utf8))
            XCTFail("expected JSONSerialization to throw")
        } catch {
            let detail = diagnosticErrorDetail(error)
            XCTAssertTrue(detail.contains("domain=NSCocoaErrorDomain"), "got: \(detail)")
            XCTAssertTrue(detail.contains("code=3840"), "got: \(detail)")
        }
    }

    func testSwiftErrorDetailCarriesTypeAndMessage() {
        let detail = diagnosticErrorDetail(LocalizedErrorMessage("no such account"))
        XCTAssertEqual(detail, "type=LocalizedErrorMessage detail=no such account")
    }

    // A DecodingError must render as DecodingError, not NSError - Swift errors bridge to NSError,
    // and if the NSError branch ran first the coding path (the field that broke) would be lost.
    // This is the diagnostic that would have made the state-decode data-loss incident debuggable.
    func testDecodingErrorNamesTheFieldThatBroke() {
        struct Sample: Decodable { let notchModeEnabled: Bool }
        let detail: String
        do {
            _ = try JSONDecoder().decode(Sample.self, from: Data("{}".utf8))
            XCTFail("expected a decoding failure")
            return
        } catch {
            detail = diagnosticErrorDetail(error)
        }
        XCTAssertTrue(detail.hasPrefix("type=DecodingError"), "got: \(detail)")
        XCTAssertTrue(detail.contains("kind=keyNotFound"), "got: \(detail)")
        XCTAssertTrue(detail.contains("notchModeEnabled"), "got: \(detail)")
    }

    func testHTTPStatusErrorCarriesStatusAndBody() {
        let detail = diagnosticErrorDetail(HTTPStatusError(statusCode: 429, body: "rate limited"))
        XCTAssertTrue(detail.contains("status=429"), "got: \(detail)")
        XCTAssertTrue(detail.contains("body=rate limited"), "got: \(detail)")
    }

    func testHTTPStatusErrorWithEmptyBodyOmitsBody() {
        let detail = diagnosticErrorDetail(HTTPStatusError(statusCode: 500, body: ""))
        XCTAssertEqual(detail, "type=HTTPStatusError status=500")
    }

    func testURLErrorCarriesCode() {
        let detail = diagnosticErrorDetail(URLError(.timedOut))
        XCTAssertTrue(detail.contains("type=URLError"), "got: \(detail)")
        XCTAssertTrue(detail.contains("code=\(URLError.timedOut.rawValue)"), "got: \(detail)")
    }

    // MARK: - Shell.output exit-code contract

    #if os(macOS)
    func testShellOutputReturnsStdoutOnSuccess() {
        XCTAssertEqual(Shell.output("/bin/echo", ["hi"]), "hi\n")
    }

    // The whole point of the fix: a process that exits non-zero returns nil, even though it may
    // have already streamed partial stdout. sqlite3 dying mid-query is the case that matters.
    func testShellOutputReturnsNilOnNonZeroExit() {
        XCTAssertNil(Shell.output("/bin/sh", ["-c", "echo partial; exit 1"]))
    }

    func testShellOutputReturnsNilWhenLaunchFails() {
        XCTAssertNil(Shell.output("/nonexistent/binary", []))
    }

    func testShellRequireThrowsWithFailureMessageOnNonZeroExit() {
        XCTAssertThrowsError(
            try Shell.require("/bin/sh", ["-c", "exit 3"], failureMessage: "boom")
        ) { error in
            XCTAssertEqual(error.localizedDescription, "boom")
        }
    }
    #endif
}
