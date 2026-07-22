import XCTest
@testable import Toki

/// Guards the `Toki usage <provider>` filter resolution - the bug this release fixed, where
/// "claude" matched `.claude` (a provider the scanner never emits) instead of `.claudeCode`,
/// so the filter silently returned nothing.
final class UsageCommandProviderResolutionTests: XCTestCase {
    // The regression, pinned: among the providers the scanner actually emits, "claude" must
    // land on Claude Code, not vanish.
    func testClaudeResolvesToClaudeCodeAmongScannedProviders() {
        let present: Set<Provider> = [.claudeCode, .openCode, .pi]
        XCTAssertEqual(UsageCommand.resolveProvider("claude", among: present), .claudeCode)
    }

    func testExactRawValueWinsOverPrefix() {
        // If `.claude` is genuinely present, an exact rawValue match takes it over the
        // Claude-Code prefix match - exact is exact.
        let present: Set<Provider> = [.claude, .claudeCode]
        XCTAssertEqual(UsageCommand.resolveProvider("claude", among: present), .claude)
    }

    func testPrefixBeatsSubstring() {
        // "open" prefixes "OpenCode" but only appears mid-word nowhere else here.
        let present: Set<Provider> = [.claudeCode, .openCode]
        XCTAssertEqual(UsageCommand.resolveProvider("open", among: present), .openCode)
    }

    func testSubstringFallbackIsDeterministic() {
        // "code" prefixes neither display name; the substring match resolves, and ties break on
        // display name so the answer never depends on Set iteration order.
        let present: Set<Provider> = [.claudeCode, .openCode]
        XCTAssertEqual(UsageCommand.resolveProvider("code", among: present), .claudeCode)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(UsageCommand.resolveProvider("xyz", among: [.claudeCode, .pi]))
    }

    func testFilterNeverInventsAProviderThatIsAbsent() {
        // "pi" must not resolve when Pi wasn't scanned, even though the enum has a .pi case.
        XCTAssertNil(UsageCommand.resolveProvider("pi", among: [.claudeCode]))
    }
}
