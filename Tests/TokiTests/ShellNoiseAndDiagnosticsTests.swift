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
        XCTAssertEqual(try SecretResolver.runShell("printf 'hi'"), "hi")
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

    func testCredentialsWithoutTokenFailWithMissingTokenMessage() {
        let credentials = #"{"claudeAiOauth":{}}"#
        XCTAssertThrowsError(try ClaudeCodeCredentialReader.extractAccessToken(from: credentials)) { error in
            XCTAssertEqual(error.localizedDescription, "No Claude Code OAuth access token found")
        }
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

    func testLocalizedErrorMessageDetailStaysMessageFree() {
        let detail = diagnosticErrorDetail(LocalizedErrorMessage("secret workspace name"))
        XCTAssertEqual(detail, "type=LocalizedErrorMessage")
    }
}
