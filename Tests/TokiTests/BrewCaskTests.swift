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
                ["fetch", "--cask", "toki-beta"],
                ["uninstall", "--cask", "toki"],
                ["install", "--cask", "toki-beta"],
            ]
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
        XCTAssertEqual(steps.map(BrewCask.isUninstall), [false, true, false])
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
