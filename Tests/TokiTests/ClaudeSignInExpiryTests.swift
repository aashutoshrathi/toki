import Foundation
import XCTest
@testable import Toki

final class ClaudeSignInExpiryTests: XCTestCase {
    private func credentials(expiresAt: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"token-123","expiresAt":\#(expiresAt)}}"#
    }

    private func milliseconds(fromNow offset: TimeInterval) -> String {
        String(Int((Date().timeIntervalSince1970 + offset) * 1000))
    }

    // MARK: - Expiry parsing

    func testExpiryIsParsedFromEpochMilliseconds() throws {
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: "1786000000000"))
        XCTAssertEqual(token.accessToken, "token-123")
        XCTAssertEqual(token.expiresAt?.timeIntervalSince1970 ?? 0, 1786000000, accuracy: 0.001)
    }

    func testExpiryIsParsedWhenStoredAsAString() throws {
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: "\"1786000000000\""))
        XCTAssertEqual(token.expiresAt?.timeIntervalSince1970 ?? 0, 1786000000, accuracy: 0.001)
    }

    func testUnusableExpiryValuesAreIgnoredRatherThanGuessed() {
        for raw in ["null", "0", "-1", #""not-a-number""#] {
            let token = try? ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: raw))
            XCTAssertNil(token?.expiresAt, "expiresAt \(raw) should not produce a date")
        }
    }

    // MARK: - Expiry decisions

    func testTokenWithoutExpiryIsNeverTreatedAsExpired() throws {
        let credentials = #"{"claudeAiOauth":{"accessToken":"token-123"}}"#
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials)
        XCTAssertNil(token.expiresAt)
        XCTAssertFalse(token.isExpired())
    }

    func testTokenPastItsExpiryIsExpired() throws {
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: milliseconds(fromNow: -3600)))
        XCTAssertTrue(token.isExpired())
    }

    func testTokenExpiringInsideTheLeewayIsTreatedAsExpired() throws {
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: milliseconds(fromNow: 30)))
        XCTAssertTrue(token.isExpired())
    }

    func testTokenComfortablyInTheFutureIsUsable() throws {
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: milliseconds(fromNow: 3600)))
        XCTAssertFalse(token.isExpired())
    }

    // MARK: - What the user is told

    func testActiveAccountIsToldToOpenClaudeCodeAndThatRecoveryIsAutomatic() {
        let message = ClaudeSignInExpiredError(accountLabel: "a@b.com", isActiveAccount: true).localizedDescription
        XCTAssertTrue(message.contains("Open Claude Code"), message)
        XCTAssertFalse(message.contains("claude-swap"), message)
    }

    func testStoredAccountIsToldToSwapAndIsNamed() {
        let message = ClaudeSignInExpiredError(accountLabel: "work@example.com", isActiveAccount: false).localizedDescription
        XCTAssertTrue(message.contains("claude-swap"), message)
        XCTAssertTrue(message.contains("work@example.com"), message)
    }

    func testExpiryMessagesNeverEchoTheToken() throws {
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: milliseconds(fromNow: -60)))
        XCTAssertTrue(token.isExpired())
        for active in [true, false] {
            let message = ClaudeSignInExpiredError(accountLabel: "a@b.com", isActiveAccount: active).localizedDescription
            XCTAssertFalse(message.contains(token.accessToken), message)
        }
    }

    // MARK: - Rate-limit classification

    func testRequestIdThatMerelyContains429IsNotMistakenForARateLimit() {
        let body = #"HTTP 401: {"type":"error","error":{"type":"authentication_error"},"request_id":"req_011Cdp429ZzcDbgSb8o9H3Wy"}"#
        XCTAssertFalse(UsageFetcher.isRateLimitDescription(body), body)
    }

    func testGenuineRateLimitBodiesAreStillRecognised() {
        let bodies = [
            #"HTTP 429: {"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}"#,
            "status 429",
            "Rate limited. Please try again later."
        ]
        for body in bodies {
            XCTAssertTrue(UsageFetcher.isRateLimitDescription(body), body)
        }
    }
}
