import XCTest
@testable import Toki

// appVersion carries only the marketing version, so the suffix saying which beta you are on
// has to come back out of the release identity the packaging scripts stamp into Info.plist.
final class PrereleaseBadgeTests: XCTestCase {
    func testBetaIdentityReadsAsItsNumber() {
        XCTAssertEqual(prereleaseBadge(for: "3.1.0-beta.3"), "BETA 3")
    }

    func testReleaseCandidateKeepsItsOwnName() {
        XCTAssertEqual(prereleaseBadge(for: "3.1.0-rc.2"), "RC 2")
    }

    func testSuffixWithoutANumberStillLabels() {
        XCTAssertEqual(prereleaseBadge(for: "3.1.0-beta"), "BETA")
    }

    func testStableIdentityHasNoBadge() {
        XCTAssertNil(prereleaseBadge(for: "3.1.0"))
    }

    // What a local dev build reports, since it falls back to the marketing version.
    func testMarketingVersionAloneHasNoBadge() {
        XCTAssertNil(prereleaseBadge(for: appVersion))
    }

    // A tag ending in a bare hyphen must not render an empty capsule.
    func testEmptySuffixIsNotABadge() {
        XCTAssertNil(prereleaseBadge(for: "3.1.0-"))
    }
}
