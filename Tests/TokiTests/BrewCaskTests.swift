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
