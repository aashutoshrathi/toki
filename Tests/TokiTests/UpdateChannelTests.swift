import XCTest
@testable import Toki

final class UpdateChannelTests: XCTestCase {
    // MARK: - Core version ordering

    func testPlainVersionOrdering() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0", than: "2.4.3"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.4.3", than: "2.5.0"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.4.3", than: "2.4.3"))
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.10.0", than: "2.9.0"))
    }

    func testShorterCoreIsPaddedWithZeros() {
        XCTAssertEqual(UpdateChecker.compareVersions("2.5", "2.5.0"), .orderedSame)
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.1", than: "2.5"))
    }

    func testCurrentVersionMayCarryTagPrefix() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0", than: "v2.4.3"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.4.3", than: "v2.4.3"))
    }

    // MARK: - Prerelease ordering (the beta channel's contract)

    func testPrereleaseIsOlderThanItsRelease() {
        // The old numeric string compare got this exactly backwards, which would have
        // reinstalled 2.5.0-beta.1 on top of the shipped 2.5.0 forever.
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.5.0-beta.1", than: "2.5.0"))
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0", than: "2.5.0-beta.1"))
    }

    func testPrereleaseIsNewerThanPreviousRelease() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-beta.1", than: "2.4.3"))
    }

    func testPrereleaseIterationsOrderNumerically() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-beta.2", than: "2.5.0-beta.1"))
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-beta.10", than: "2.5.0-beta.9"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.5.0-beta.1", than: "2.5.0-beta.1"))
    }

    func testPrereleaseIdentifierRules() {
        // Fewer identifiers sort first: -beta < -beta.1 (semver spec rule 11).
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-beta.1", than: "2.5.0-beta"))
        // Numeric identifiers sort below alphanumeric ones: -1 < -beta.
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-beta", than: "2.5.0-1"))
        // Alphanumeric identifiers compare lexically: -alpha < -beta < -rc.
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-beta.1", than: "2.5.0-alpha.4"))
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0-rc.1", than: "2.5.0-beta.9"))
    }

    func testBuildMetadataIsIgnored() {
        XCTAssertEqual(UpdateChecker.compareVersions("2.5.0+abc123", "2.5.0"), .orderedSame)
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.5.0+abc123", than: "2.5.0"))
    }

    func testMalformedVersionsDoNotTrap() {
        XCTAssertFalse(UpdateChecker.isNewerVersion("", than: "2.4.3"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("nonsense", than: "2.4.3"))
    }

    // MARK: - Graduation scenarios

    func testBetaBuildGraduatesToStableRelease() {
        // A tester on the beta channel running 2.5.0-beta.2 must be offered the shipped
        // 2.5.0, both while still on beta and after switching back to stable.
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.0", than: "2.5.0-beta.2"))
    }

    func testStableUserNeverDowngradedByOldBeta() {
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.5.0-beta.2", than: "2.5.0"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.5.0-beta.2", than: "2.5.1"))
    }

    func testBetaChannelPicksHighestVersionNotListOrder() {
        // Mirrors fetchCandidateRelease's max-by-version selection: a stable release
        // published after a newer beta must not shadow it, and vice versa.
        let published = ["2.5.0-beta.1", "2.4.3", "2.5.0-beta.2"]
        let best = published.max {
            UpdateChecker.compareVersions($0, $1) == .orderedAscending
        }
        XCTAssertEqual(best, "2.5.0-beta.2")
    }

    // MARK: - Channel defaults

    func testChannelParsesFromStoredRawValue() {
        XCTAssertEqual(UpdateChannel(rawValue: "beta"), .beta)
        XCTAssertEqual(UpdateChannel(rawValue: "stable"), .stable)
        XCTAssertNil(UpdateChannel(rawValue: "nightly"))
    }
}
