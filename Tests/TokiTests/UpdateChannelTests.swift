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

    // Only works when the build reports its full beta identity, which is why release builds carry
    // TokiReleaseVersion rather than the dotted-numeric CFBundleShortVersionString.
    func testBetaSeesNextBetaAndGraduatesToStable() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.1-beta.3", than: "2.5.1-beta.2"))
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.5.1", than: "2.5.1-beta.2"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("2.5.1-beta.2", than: "2.5.1"))
    }

    func testInstalledVersionFallsBackToMarketingVersionWithoutTheKey() {
        XCTAssertEqual(UpdateChecker.installedVersion, appVersion)
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

    func testWhyUpdateReadsTheOneLineFromReleaseNotes() {
        let notes = """
        ## 3.3.8 - 2026-10-04

        One Line: Resets can no longer be **lost**.

        ### Fixed
        - Something
        """
        XCTAssertEqual(UpdateChecker.whyUpdateLine(fromNotes: notes), "Resets can no longer be lost.")
        XCTAssertEqual(UpdateChecker.whyUpdateLine(fromNotes: "one line:   Faster `refresh`"), "Faster refresh")
        XCTAssertNil(UpdateChecker.whyUpdateLine(fromNotes: "## 3.3.7\n- Added things"))
        XCTAssertNil(UpdateChecker.whyUpdateLine(fromNotes: "One Line:   "))
    }

    // MARK: - Architecture-aware asset selection & verification

    private func asset(_ name: String) -> GitHubRelease.Asset {
        GitHubRelease.Asset(
            name: name,
            browserDownloadURL: URL(string: "https://github.com/aashutoshrathi/toki/releases/download/v3.4.6/\(name)")!
        )
    }

    func testUniversalDMGNameSortsBeforePerArchDMGs() {
        // Shipped builds <= 3.4.5 pick the first ".dmg" asset in GitHub's alphabetically sorted
        // release listing, so Toki_<v>_all.dmg must sort before _arm64 and _x86_64 under both
        // byte-order and Unicode/locale case-insensitive comparisons.
        let names = ["Toki_3.4.6_x86_64.dmg", "Toki_3.4.6_arm64.dmg", "Toki_3.4.6_all.dmg"]
        XCTAssertEqual(names.sorted().first, "Toki_3.4.6_all.dmg")
        XCTAssertEqual(
            names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.first,
            "Toki_3.4.6_all.dmg"
        )
    }

    func testSelectDMGAssetPicksNativeArchitectureRegardlessOfOrder() {
        let releaseAssets = [
            asset("Toki-windows-preview-4.0.0-win-x64.zip"),
            asset("Toki_3.4.6_all.dmg"),
            asset("Toki_3.4.6_arm64.dmg"),
            asset("Toki_3.4.6_x86_64.dmg"),
        ]

        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: releaseAssets, releaseVersion: "3.4.6", preferredArch: .arm64)?.name,
            "Toki_3.4.6_arm64.dmg"
        )
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: releaseAssets, releaseVersion: "3.4.6", preferredArch: .x86_64)?.name,
            "Toki_3.4.6_x86_64.dmg"
        )
        // Reversed ordering must return the exact same architecture-specific assets.
        let reversed = Array(releaseAssets.reversed())
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: reversed, releaseVersion: "3.4.6-beta.1", preferredArch: .arm64)?.name,
            "Toki_3.4.6_arm64.dmg"
        )
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: reversed, releaseVersion: "3.4.6-beta.1", preferredArch: .x86_64)?.name,
            "Toki_3.4.6_x86_64.dmg"
        )
    }

    func testSelectDMGAssetFallsBackToUniversalWhenThinAssetMissing() {
        let newUniversalOnly = [asset("Toki_3.4.6_all.dmg")]
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: newUniversalOnly, releaseVersion: "3.4.6", preferredArch: .arm64)?.name,
            "Toki_3.4.6_all.dmg"
        )
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: newUniversalOnly, releaseVersion: "3.4.6", preferredArch: .x86_64)?.name,
            "Toki_3.4.6_all.dmg"
        )

        let legacyUniversalOnly = [asset("Toki_3.4.5_universal.dmg")]
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: legacyUniversalOnly, releaseVersion: "3.4.5", preferredArch: .arm64)?.name,
            "Toki_3.4.5_universal.dmg"
        )
        XCTAssertEqual(
            UpdateChecker.selectDMGAsset(from: legacyUniversalOnly, releaseVersion: "3.4.5", preferredArch: .x86_64)?.name,
            "Toki_3.4.5_universal.dmg"
        )
    }

    func testSelectDMGAssetNeverSelectsOppositeArchitecture() {
        let armOnly = [asset("Toki_3.4.6_arm64.dmg")]
        XCTAssertNil(
            UpdateChecker.selectDMGAsset(from: armOnly, releaseVersion: "3.4.6", preferredArch: .x86_64)
        )

        let intelOnly = [asset("Toki_3.4.6_x86_64.dmg")]
        XCTAssertNil(
            UpdateChecker.selectDMGAsset(from: intelOnly, releaseVersion: "3.4.6", preferredArch: .arm64)
        )

        let nonDMGOnly = [asset("Toki-windows-preview-4.0.0-win-x64.zip")]
        XCTAssertNil(
            UpdateChecker.selectDMGAsset(from: nonDMGOnly, releaseVersion: "4.0.0", preferredArch: .arm64)
        )
    }

    func testInstallerArchitectureAndReleaseMetadataVerification() {
        XCTAssertTrue(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "arm64\n", preferredArch: .arm64))
        XCTAssertFalse(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "arm64\n", preferredArch: .x86_64))
        XCTAssertTrue(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "x86_64\n", preferredArch: .x86_64))
        XCTAssertFalse(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "x86_64\n", preferredArch: .arm64))
        XCTAssertTrue(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "x86_64 arm64\n", preferredArch: .arm64))
        XCTAssertTrue(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "x86_64 arm64\n", preferredArch: .x86_64))
        XCTAssertFalse(UpdateInstaller.supportsHostArchitecture(lipoArchsOutput: "", preferredArch: .arm64))

        XCTAssertTrue(UpdateInstaller.releaseMetadataMatches(
            bundleID: "local.toki",
            marketingVersion: "3.4.6",
            releaseVersionStamp: "3.4.6-beta.2",
            expectedVersion: "3.4.6-beta.2"
        ))
        XCTAssertFalse(UpdateInstaller.releaseMetadataMatches(
            bundleID: "local.toki",
            marketingVersion: "3.4.6",
            releaseVersionStamp: "3.4.6-beta.1",
            expectedVersion: "3.4.6-beta.2"
        ))
        XCTAssertTrue(UpdateInstaller.releaseMetadataMatches(
            bundleID: "local.toki",
            marketingVersion: "3.4.6",
            releaseVersionStamp: nil,
            expectedVersion: "3.4.6"
        ))
    }
}
