import XCTest
@testable import Toki

// A launch that finds no usable config.json takes the onboarding path, and that path now writes a
// preference (the checklist has started). Writing state before the saved state has been read back
// persists the initializer's empty defaults over the real file, taking events, history, the
// running session and per-account usage with it - and a machine using only local-history
// providers never gets a config.json, so it would take that path on every single launch.
@MainActor
final class OnboardingStatePreservationTests: XCTestCase {
    private var directory: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("state.json")
        setenv("TOKI_STATE", stateURL.path, 1)
        // Deliberately never created: this is the "no config yet" launch.
        setenv("TOKI_CONFIG", directory.appendingPathComponent("config.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TOKI_STATE")
        unsetenv("TOKI_CONFIG")
        try? FileManager.default.removeItem(at: directory)
    }

    func testALaunchWithNoConfigKeepsTheStateItAlreadyHad() throws {
        var saved = UsageState()
        saved.preferences.historyRetentionDays = 21
        saved.events = [TokiEvent(kind: .refresh, title: "before", detail: "", deliveredNotification: false)]
        saved.history = [UsageHistoryEntry(
            accountID: "codex", accountName: "Codex", provider: .codex, remainingRatio: 0.5, primary: "50%"
        )]
        try JSONEncoder.toki.encode(saved).write(to: stateURL)

        let store = UsageStore()
        XCTAssertTrue(store.needsOnboarding, "no config.json means this is the onboarding path")

        let reloaded = StateLoader.load()
        XCTAssertEqual(reloaded.events.count, 1, "events must survive a launch with no config")
        XCTAssertEqual(reloaded.history.count, 1, "history must survive a launch with no config")
        XCTAssertEqual(reloaded.preferences.historyRetentionDays, 21, "settings must survive it too")
        // The reason the write happens at all: onboarding records that the checklist has begun.
        XCTAssertTrue(reloaded.preferences.setupChecklistStarted)
        withExtendedLifetime(store) {}
    }
}
