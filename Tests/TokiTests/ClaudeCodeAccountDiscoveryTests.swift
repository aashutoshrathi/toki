import XCTest
@testable import Toki

final class ClaudeCodeAccountDiscoveryTests: XCTestCase {
    func testCustomDirectoryBypassesDefaultSwapAccounts() {
        let path = "/tmp/claude-work/.credentials.json"
        let custom = record(id: "work", email: "work@example.com", source: path)
        let defaultAccount = record(id: "claude-1-personal", email: "personal@example.com", source: "Keychain test active")

        let records = ClaudeCodeAccountDiscovery.discover(
            customCredentialFilePath: path,
            swapRecords: {
                XCTFail("A custom directory must not read the default swap registry")
                return [defaultAccount]
            },
            fallbackRecord: { custom }
        )

        XCTAssertEqual(records, [custom])
    }

    func testWithoutCustomDirectoryPreservesSwapDiscovery() {
        let active = record(id: "claude-1-personal", email: "personal@example.com", source: "Keychain test active")
        let stored = record(id: "claude-2-work", email: "work@example.com", source: "claude-swap 2")

        let records = ClaudeCodeAccountDiscovery.discover(
            customCredentialFilePath: nil,
            swapRecords: { [active, stored] },
            fallbackRecord: {
                XCTFail("The default swap accounts must retain precedence")
                return active
            }
        )

        XCTAssertEqual(records, [active, stored])
    }

    private func record(id: String, email: String, source: String) -> ClaudeCodeAccountRecord {
        ClaudeCodeAccountRecord(
            id: id, name: email, email: email, organizationName: nil, organizationUUID: nil,
            accountNumber: nil, isActive: true, source: source, credentials: nil,
            loadError: nil, label: nil
        )
    }
}
