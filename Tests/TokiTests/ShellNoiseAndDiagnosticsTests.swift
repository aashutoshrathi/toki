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
