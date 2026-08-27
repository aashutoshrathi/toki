import XCTest
@testable import Toki

@MainActor
final class AccountRenameTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("TOKI_CONFIG", directory.appendingPathComponent("config.json").path, 1)
        setenv("TOKI_STATE", directory.appendingPathComponent("state.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TOKI_CONFIG")
        unsetenv("TOKI_STATE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(id: String, name: String, provider: Provider) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: name,
            provider: provider,
            primary: "",
            subtitle: "",
            remainingRatio: nil,
            metrics: []
        )
    }

    private func store(accounts: [AccountConfig], snapshots: [AccountSnapshot]) throws -> UsageStore {
        let config = AppConfig(refreshMinutes: nil, accountLabels: nil, accounts: accounts, aiInstructions: nil)
        try ConfigLoader.save(config)
        let store = UsageStore()
        store.config = config
        store.snapshots = snapshots
        return store
    }

    func testRenamingAnAutoDetectedProviderPersistsIt() throws {
        let sarvam = snapshot(id: "sarvam-code-auto", name: "Sarvam Code", provider: .sarvamCode)
        let store = try store(
            accounts: [AccountConfig(id: "claude-code", name: "Claude Code", provider: .claudeCode)],
            snapshots: [sarvam]
        )

        store.renameAccount(snapshot: sarvam, alias: "Sarvam")

        let saved = try ConfigLoader.load()
        let entry = saved.accounts.first { $0.provider == .sarvamCode }
        XCTAssertEqual(entry?.name, "Sarvam")
        XCTAssertEqual(entry?.id, "sarvam-code-auto", "reusing the id keeps history keyed to it")
        XCTAssertEqual(store.snapshots.first?.name, "Sarvam")
        XCTAssertNil(store.configError)
    }

    func testRenamingTheSameProviderTwiceUpdatesInsteadOfDuplicating() throws {
        let sarvam = snapshot(id: "sarvam-code-auto", name: "Sarvam Code", provider: .sarvamCode)
        let store = try store(accounts: [], snapshots: [sarvam])

        store.renameAccount(snapshot: sarvam, alias: "Sarvam")
        store.renameAccount(snapshot: store.snapshots[0], alias: "Sarvam AI")

        let saved = try ConfigLoader.load()
        XCTAssertEqual(saved.accounts.filter { $0.provider == .sarvamCode }.count, 1)
        XCTAssertEqual(saved.accounts.first { $0.provider == .sarvamCode }?.name, "Sarvam AI")
    }

    func testRenamingAConfiguredAccountStillUpdatesInPlace() throws {
        let sarvam = snapshot(id: "sarvam-code-auto", name: "Sarvam Code", provider: .sarvamCode)
        let store = try store(
            accounts: [AccountConfig(id: "sarvam-code-auto", name: "Sarvam Code", provider: .sarvamCode)],
            snapshots: [sarvam]
        )

        store.renameAccount(snapshot: sarvam, alias: "Sarvam AI")

        let saved = try ConfigLoader.load()
        XCTAssertEqual(saved.accounts.count, 1)
        XCTAssertEqual(saved.accounts[0].name, "Sarvam AI")
    }

    func testAClaudeSnapshotWithoutAnEmailDoesNotAppendAStrayAccount() throws {
        let claude = snapshot(id: "claude-1-unknown", name: "Claude", provider: .claudeCode)
        let store = try store(
            accounts: [AccountConfig(id: "claude-code", name: "Claude Code", provider: .claudeCode)],
            snapshots: [claude]
        )

        store.renameAccount(snapshot: claude, alias: "Personal")

        let saved = try ConfigLoader.load()
        XCTAssertEqual(saved.accounts.count, 1)
        XCTAssertEqual(saved.accounts[0].id, "claude-code")
    }
}
