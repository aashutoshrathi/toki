import XCTest
@testable import Toki

final class BrewCaskTests: XCTestCase {
    private var tempCaskroom: URL!

    override func setUp() {
        super.setUp()
        tempCaskroom = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewCaskTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempCaskroom, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempCaskroom)
        super.tearDown()
    }

    func testDetectsInstalledCaskAndPrefix() throws {
        // The real layout: the cask's symlink points from the Caskroom to the installed
        // app, which lives somewhere else entirely.
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewCaskTests-apps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appDir) }
        let bundle = appDir.appendingPathComponent("Toki.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let versionDir = tempCaskroom.appendingPathComponent("toki-beta").appendingPathComponent("2.7.0")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: versionDir.appendingPathComponent("Toki.app"),
            withDestinationURL: URL(fileURLWithPath: bundle.path)
        )

        let install = BrewCask.installedCask(
            bundleURL: bundle,
            caskroomBases: [tempCaskroom]
        )
        XCTAssertEqual(install?.cask, "toki-beta")
        XCTAssertEqual(install?.brewPrefix, tempCaskroom.deletingLastPathComponent().path)
        XCTAssertNil(BrewCask.installedCask(
            bundleURL: URL(fileURLWithPath: "/Applications/Toki.app"),
            caskroomBases: [tempCaskroom]
        ))
    }

    func testHandoffReadsVersionAfterTheBundleIsReplacedInPlace() throws {
        // Foundation caches a Bundle per path, so reading through `Bundle(url:)` would
        // still report the version from before brew swapped the app.
        let app = tempCaskroom.appendingPathComponent("Toki.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        func writeInfoPlist(release: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["TokiReleaseVersion": release], format: .xml, options: 0
            )
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }

        try writeInfoPlist(release: "2.5.0-beta.1")
        XCTAssertFalse(BrewCask.handoffSucceeded(appURL: app, expectedVersion: "2.5.0-beta.2"))
        try writeInfoPlist(release: "2.5.0-beta.2")
        XCTAssertTrue(BrewCask.handoffSucceeded(appURL: app, expectedVersion: "2.5.0-beta.2"))
    }

    func testSwitchingCasksUninstallsOnlyAfterTheDownloadIsCached() {
        // The uninstall deletes the running bundle, so a fetch that fails must fail before
        // anything is removed.
        XCTAssertEqual(
            BrewCask.switchCommands(from: BrewCask.stableCask, to: BrewCask.betaCask),
            [
                ["update", "--quiet"],
                ["fetch", "--cask", "aashutoshrathi/tap/toki-beta"],
                ["uninstall", "--cask", "toki"],
                ["install", "--cask", "aashutoshrathi/tap/toki-beta"],
            ]
        )
    }

    /// `fetch` is not a command brew auto-updates a tap for, but `install` is, so without a
    /// refresh up front the fetch could cache one version and the install resolve a newer one
    /// with the old app already deleted - which is exactly what fetching first exists to avoid.
    func testTheTapIsRefreshedBeforeAnythingIsCachedOrRemoved() {
        let steps = BrewCask.switchCommands(from: BrewCask.stableCask, to: BrewCask.betaCask)
        let refresh = steps.firstIndex(of: BrewCask.refreshCommand)
        let fetch = steps.firstIndex { $0.first == "fetch" }
        let uninstall = steps.firstIndex(where: BrewCask.isUninstall)
        XCTAssertNotNil(refresh)
        XCTAssertNotNil(fetch)
        XCTAssertNotNil(uninstall)
        XCTAssertLessThan(refresh!, fetch!)
        XCTAssertLessThan(fetch!, uninstall!)
    }

    /// Homebrew refreshes a third-party tap every 24 hours for a bare token and every 5
    /// minutes for one that names its tap, so a bare `brew upgrade --cask toki` spends the
    /// first day of a release resolving against a snapshot taken before it existed - and
    /// reports that as "the latest version is already installed" with an exit status of 0.
    func testEveryStepThatResolvesAVersionNamesTheTap() {
        XCTAssertEqual(
            BrewCask.upgradeCommand(for: BrewCask.stableCask),
            ["upgrade", "--cask", "aashutoshrathi/tap/toki"]
        )
        XCTAssertEqual(
            BrewCask.installCommand(for: BrewCask.betaCask),
            ["install", "--cask", "aashutoshrathi/tap/toki-beta"]
        )
        // An uninstall reads the Caskroom, not the tap, and naming a tap it no longer has
        // would be the one way to make removing an installed cask fail.
        let uninstall = BrewCask.switchCommands(from: BrewCask.stableCask, to: BrewCask.betaCask)
            .first(where: BrewCask.isUninstall)
        XCTAssertEqual(uninstall, ["uninstall", "--cask", "toki"])
    }

    /// The upgrade that just reported nothing to do cannot be the advice for it having done
    /// nothing: `update` refreshes the tap and `reinstall` ignores a receipt that already
    /// claims the new version.
    func testRecoveryAdviceDoesNotSendAnyoneRoundTheSameNoOp() {
        let advice = BrewCask.recoveryAdvice(for: BrewCask.stableCask)
        XCTAssertEqual(advice, "Run `brew update && brew reinstall --cask aashutoshrathi/tap/toki`.")
        XCTAssertFalse(advice.contains("brew upgrade"))
        XCTAssertEqual(BrewCask.refreshCommand, ["update", "--quiet"])
    }

    /// The warning brew prints for a no-op upgrade is the line the user needs to see, and it
    /// arrives on a run that exited 0, so it has to survive the "no Error: line" fallback.
    func testTheNoOpUpgradeWarningIsWhatGetsReported() {
        let output = """
        ==> Auto-updating Homebrew...
        Warning: Not upgrading toki, the latest version is already installed
        """
        XCTAssertEqual(
            BrewCask.failureReason(output),
            "Warning: Not upgrading toki, the latest version is already installed"
        )
    }

    /// Homebrew 6 records cask trust per cask, so installing `toki` leaves `toki-beta`
    /// untrusted and every switch command against it is refused.
    func testTheTargetCaskIsTrustedByItsFullyQualifiedName() {
        XCTAssertEqual(
            BrewCask.trustCommand(for: BrewCask.betaCask),
            ["trust", "--cask", "aashutoshrathi/tap/toki-beta"]
        )
    }

    /// Trusting the tap would cover everything published there; only the sibling cask is wanted.
    func testTrustNamesOneCaskRatherThanTheWholeTap() {
        XCTAssertFalse(BrewCask.trustCommand(for: BrewCask.betaCask).contains("--tap"))
        XCTAssertEqual(BrewCask.qualified(BrewCask.stableCask), "aashutoshrathi/tap/toki")
    }

    func testOnlyTheUninstallStepCountsAsRemovingTheApp() {
        let steps = BrewCask.switchCommands(from: BrewCask.stableCask, to: BrewCask.betaCask)
        XCTAssertEqual(steps.map(BrewCask.isUninstall), [false, false, true, false])
    }

    func testFailureReasonPrefersBrewsOwnErrorLine() {
        let output = """
        ==> Downloading https://example.com/Toki.dmg
        Error: Refusing to load cask aashutoshrathi/tap/toki-beta from untrusted tap.
        Run `brew trust --cask aashutoshrathi/tap/toki-beta` to trust it.
        """
        XCTAssertEqual(
            BrewCask.failureReason(output),
            "Error: Refusing to load cask aashutoshrathi/tap/toki-beta from untrusted tap."
        )
    }

    func testFailureReasonFallsBackToTheLastThingSaid() {
        XCTAssertEqual(BrewCask.failureReason("something went sideways\n\n"), "something went sideways")
        XCTAssertNil(BrewCask.failureReason("   \n  \n"))
    }

    func testHandoffPostconditionDistinguishesBetaIterations() {
        XCTAssertTrue(BrewCask.handoffSucceeded(
            bundleVersion: "2.5.0-beta.2", marketingVersion: "2.5.0", expectedVersion: "2.5.0-beta.2"
        ))
        XCTAssertFalse(BrewCask.handoffSucceeded(
            bundleVersion: "2.5.0-beta.1", marketingVersion: "2.5.0", expectedVersion: "2.5.0-beta.2"
        ))
        // Without a release stamp a beta iteration is indistinguishable from its
        // siblings, so only an exact stable match may pass.
        XCTAssertFalse(BrewCask.handoffSucceeded(
            bundleVersion: nil, marketingVersion: "2.5.0", expectedVersion: "2.5.0-beta.1"
        ))
        XCTAssertTrue(BrewCask.handoffSucceeded(
            bundleVersion: nil, marketingVersion: "2.5.0", expectedVersion: "2.5.0"
        ))
    }
}
