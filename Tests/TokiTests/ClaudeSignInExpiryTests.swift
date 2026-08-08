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

    // A JSON boolean bridges to NSNumber; `true` would otherwise read as 1ms past the epoch and
    // report a usable token as long expired.
    func testBooleanExpiryIsNotMistakenForAnEpoch() throws {
        for raw in ["true", "false"] {
            let token = try ClaudeCodeCredentialReader.extractToken(from: credentials(expiresAt: raw))
            XCTAssertNil(token.expiresAt, "expiresAt \(raw) should not produce a date")
            XCTAssertFalse(token.isExpired(), "expiresAt \(raw) should leave the token usable")
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

    // MARK: - Disposition: what the client does before ever touching the network

    private func record(credentials: String?, isActive: Bool = true, email: String? = "a@b.com", loadError: String? = nil) -> ClaudeCodeAccountRecord {
        ClaudeCodeAccountRecord(
            id: "claude-1-a@b.com",
            name: email ?? "Claude",
            email: email,
            organizationName: nil,
            organizationUUID: nil,
            accountNumber: 1,
            isActive: isActive,
            source: "test",
            credentials: credentials,
            loadError: loadError,
            label: nil
        )
    }

    private func credentialBlob(expiresAt: TimeInterval) -> String {
        let millis = Int((Date().timeIntervalSince1970 + expiresAt) * 1000)
        return #"{"claudeAiOauth":{"accessToken":"live-token","expiresAt":\#(millis)}}"#
    }

    // The regression that shipped: an expired token was sent anyway and came back 401. The
    // decision must reach `.expired` without ever yielding a token to send.
    func testExpiredTokenIsNeverOfferedForUse() throws {
        let disposition = try ClaudeCodeUsageClient.disposition(for: record(credentials: credentialBlob(expiresAt: -3600)))
        guard case .expired(let expiry) = disposition else {
            return XCTFail("expected .expired, got \(disposition)")
        }
        XCTAssertTrue(expiry.isActiveAccount)
    }

    // The mirror-image regression to guard against: a good token must NOT be misread as expired,
    // or a working account would show "Signed out" and never call the API.
    func testValidTokenIsOfferedForUse() throws {
        let disposition = try ClaudeCodeUsageClient.disposition(for: record(credentials: credentialBlob(expiresAt: 3600)))
        XCTAssertEqual(disposition, .useToken("live-token"))
    }

    func testTokenWithNoExpiryIsOfferedForUse() throws {
        let blob = #"{"claudeAiOauth":{"accessToken":"live-token"}}"#
        XCTAssertEqual(try ClaudeCodeUsageClient.disposition(for: record(credentials: blob)), .useToken("live-token"))
    }

    func testInactiveStoredAccountReportsTheSwapRemedyWhenExpired() throws {
        let disposition = try ClaudeCodeUsageClient.disposition(for: record(credentials: credentialBlob(expiresAt: -60), isActive: false))
        guard case .expired(let expiry) = disposition else {
            return XCTFail("expected .expired, got \(disposition)")
        }
        XCTAssertFalse(expiry.isActiveAccount)
        XCTAssertTrue(expiry.localizedDescription.contains("claude-swap"), expiry.localizedDescription)
    }

    func testMissingCredentialsThrowRatherThanReportingExpiry() {
        XCTAssertThrowsError(try ClaudeCodeUsageClient.disposition(for: record(credentials: nil)))
        XCTAssertThrowsError(try ClaudeCodeUsageClient.disposition(for: record(credentials: "")))
    }

    func testLoadErrorSurfacesRatherThanReportingExpiry() {
        XCTAssertThrowsError(try ClaudeCodeUsageClient.disposition(for: record(credentials: credentialBlob(expiresAt: 3600), loadError: "Keychain locked"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain locked"), error.localizedDescription)
        }
    }

    // MARK: - Throttle: an expired sibling must not un-throttle a working account

    private func snapshot(expired: Bool) -> AccountSnapshot {
        AccountSnapshot(
            id: expired ? "claude-2" : "claude-1",
            name: "Claude",
            provider: .claudeCode,
            primary: expired ? "Signed out" : "80% left",
            subtitle: "a@b.com",
            remainingRatio: expired ? nil : 0.8,
            metrics: [],
            isError: expired,
            switchTarget: nil,
            switchCommand: nil,
            emoji: nil,
            colorHex: nil,
            isSignInExpired: expired
        )
    }

    func testTimestampIsSuppressedOnlyWhenEveryAccountExpired() {
        XCTAssertTrue(UsageFetcher.suppressesAPICallTimestamp([snapshot(expired: true)]))
        XCTAssertTrue(UsageFetcher.suppressesAPICallTimestamp([snapshot(expired: true), snapshot(expired: true)]))
    }

    func testTimestampIsRecordedWhenAnyAccountMadeACall() {
        // The user's exact setup: one working account, one expired stored account. The working
        // account's call must be timestamped so it is not re-polled every tick.
        XCTAssertFalse(UsageFetcher.suppressesAPICallTimestamp([snapshot(expired: false), snapshot(expired: true)]))
        XCTAssertFalse(UsageFetcher.suppressesAPICallTimestamp([snapshot(expired: false)]))
        XCTAssertFalse(UsageFetcher.suppressesAPICallTimestamp([]))
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
