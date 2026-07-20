import XCTest
@testable import Toki

final class AccountDisplayNameTests: XCTestCase {
    private func record(
        name: String = "user@example.com",
        email: String? = "user@example.com",
        nickname: String? = nil
    ) -> ClaudeCodeAccountRecord {
        ClaudeCodeAccountRecord(
            id: "claude-1-user@example.com",
            name: name,
            email: email,
            organizationName: nil,
            organizationUUID: nil,
            accountNumber: 1,
            isActive: true,
            source: "claude-swap 1",
            credentials: nil,
            loadError: nil,
            label: nickname.map { AccountPresentation(nickname: $0, emoji: nil, color: nil) }
        )
    }

    func testEmailIsPrefixedWithProviderName() {
        XCTAssertEqual(record().displayName, "Claude - user@example.com")
    }

    func testNicknameWinsOverEmail() {
        XCTAssertEqual(record(nickname: "Claude San").displayName, "Claude San")
    }

    func testEmptyNicknameFallsBackToEmail() {
        XCTAssertEqual(record(nickname: "").displayName, "Claude - user@example.com")
    }

    func testMissingEmailFallsBackToBareProviderName() {
        XCTAssertEqual(record(email: nil).displayName, "Claude")
    }

    // The registry's machine key must never surface as a label, however the record
    // was populated - that raw "claude-1-<email>" form is the bug this guards.
    func testDisplayNameNeverExposesTheRegistryKey() {
        XCTAssertFalse(record(name: "claude-1-user@example.com").displayName.hasPrefix("claude-1-"))
    }
}
