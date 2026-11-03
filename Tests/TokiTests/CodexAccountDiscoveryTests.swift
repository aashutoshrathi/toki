import Foundation
import XCTest
@testable import Toki

final class CodexAccountDiscoveryTests: XCTestCase {
    private var homeDirectory: String!

    override func setUpWithError() throws {
        homeDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: homeDirectory)
    }

    func testDefaultHomeIsAlwaysOfferedFirst() {
        let accounts = ProviderDetection.codexHomeAccounts(homeDirectory: homeDirectory)

        XCTAssertEqual(accounts.map(\.id), ["codex"])
        XCTAssertNil(accounts.first?.codexAuthPath)
    }

    func testSiblingHomesWithCodexFilesBecomeExtraAccounts() throws {
        try makeHome(".codex", file: "auth.json")
        try makeHome(".codex-work", file: "auth.json")
        try makeHome(".codex2", file: "config.toml")
        try makeHome(".codex_Side Project", file: "auth.json")

        let accounts = ProviderDetection.codexHomeAccounts(homeDirectory: homeDirectory)

        XCTAssertEqual(accounts.map(\.id), ["codex", "codex-work", "codex-2", "codex-side-project"])
        XCTAssertEqual(accounts.map(\.name), ["Codex", "Codex (work)", "Codex (2)", "Codex (Side Project)"])
        XCTAssertEqual(accounts.map(\.codexAuthPath), [
            nil, "~/.codex-work/auth.json", "~/.codex2/auth.json", "~/.codex_Side Project/auth.json"
        ])
    }

    func testFoldersWithoutCodexFilesAreSkipped() throws {
        try makeHome(".codex-empty", file: nil)
        try makeHome(".codex-notes", file: "notes.txt")
        try makeHome(".codex-", file: "auth.json")
        FileManager.default.createFile(atPath: path(".codexrc"), contents: Data())

        let accounts = ProviderDetection.codexHomeAccounts(homeDirectory: homeDirectory)

        XCTAssertEqual(accounts.map(\.id), ["codex"])
    }

    func testCapitalisedHomeIsDiscovered() throws {
        try makeHome(".Codex-Work", file: "auth.json")

        let accounts = ProviderDetection.codexHomeAccounts(homeDirectory: homeDirectory)

        XCTAssertEqual(accounts.map(\.id), ["codex", "codex-work"])
        XCTAssertEqual(accounts.last?.name, "Codex (Work)")
    }

    func testCollidingIDsGetAFreeSuffix() {
        let accounts = ["codex-work", "codex-work", "codex-2"].map {
            AccountConfig(id: $0, name: "Codex", provider: .codex)
        }

        let ids = ProviderDetection.withFreeIDs(accounts, taken: ["codex-2"]).map(\.id)

        XCTAssertEqual(ids, ["codex-work", "codex-work-2", "codex-2-2"])
    }

    func testConfiguredLoginWinsOverTheSameLoginInANewHome() {
        let work = account("work", authPath: "~/.codex-work/auth.json")
        let defaultHome = account("codex", authPath: nil)

        let offers = ProviderDetection.codexAccountsToOffer(
            [work, defaultHome],
            probes: [.signedIn(email: "me@example.com", identity: "me@example.com|acct"),
                     .signedIn(email: "me@example.com", identity: "me@example.com|acct")],
            configuredIDs: ["work"]
        )

        XCTAssertEqual(offers.map(\.account.id), ["work"])
    }

    func testNewHomeIsHeldBackWhenAnEarlierLoginIsUnknown() {
        let defaultHome = account("codex", authPath: nil)
        let backup = account("codex-bak", authPath: "~/.codex.bak/auth.json")
        let other = account("codex-other", authPath: "~/.codex-other/auth.json")

        let offers = ProviderDetection.codexAccountsToOffer(
            [defaultHome, backup, other],
            probes: [.failed, .signedIn(email: "me@example.com", identity: "me@example.com|acct"), .signedOut],
            configuredIDs: []
        )

        XCTAssertTrue(offers.isEmpty)
    }

    func testConfiguredAccountsStillShowAfterAFailedProbe() {
        let broken = account("codex", authPath: nil)
        let work = account("work", authPath: "~/.codex-work/auth.json")

        let offers = ProviderDetection.codexAccountsToOffer(
            [broken, work],
            probes: [.failed, .signedIn(email: "work@example.com", identity: "work@example.com|acct")],
            configuredIDs: ["codex", "work"]
        )

        XCTAssertEqual(offers.map(\.account.id), ["work"])
    }

    func testSymlinkedHomeIsTheSameHome() throws {
        try makeHome("real-home", file: "auth.json")
        try FileManager.default.createSymbolicLink(atPath: path(".codex-link"), withDestinationPath: path("real-home"))

        XCTAssertTrue(CodexAppServerClient.sameHome(
            account("a", authPath: path("real-home") + "/auth.json"),
            account("b", authPath: path(".codex-link") + "/auth.json")
        ))
        XCTAssertFalse(CodexAppServerClient.sameHome(
            account("a", authPath: path("real-home") + "/auth.json"),
            account("b", authPath: path("missing-home") + "/auth.json")
        ))
    }

    func testIdentityUsesTheWorkspaceAccountID() {
        let first: [String: Any] = [
            "account": ["email": "person@example.com", "planType": "team"],
            "workspaceRouting": ["chatgptAccountId": "workspace-1"]
        ]
        let second: [String: Any] = [
            "account": ["email": "person@example.com", "planType": "team"],
            "workspaceRouting": ["chatgptAccountId": "workspace-2"]
        ]

        XCTAssertEqual(CodexAccountInfo.identity(from: first), "person@example.com|workspace-1")
        XCTAssertNotEqual(CodexAccountInfo.identity(from: first), CodexAccountInfo.identity(from: second))
    }

    func testIdentityTellsPlansOfOneEmailApart() {
        let personal: [String: Any] = ["account": ["email": "person@example.com", "planType": "plus"]]
        let team: [String: Any] = ["account": ["email": "person@example.com", "planType": "team"]]
        let apiKey: [String: Any] = ["account": ["type": "apiKey"]]

        XCTAssertEqual(CodexAccountInfo.identity(from: personal), "person@example.com|plus")
        XCTAssertNotEqual(CodexAccountInfo.identity(from: personal), CodexAccountInfo.identity(from: team))
        XCTAssertNil(CodexAccountInfo.identity(from: apiKey))
    }

    func testDefaultCodexCandidateMatchesAnAccountOnTheDefaultHome() {
        let configured = AccountConfig(id: "my-codex", name: "Mine", provider: .codex)

        XCTAssertTrue(detectedProviderIsConnected(codex(id: "codex", authPath: nil), snapshotProviders: [.codex], accounts: [configured]))
    }

    func testExtraCodexHomeIsNewWhenOnlyTheDefaultIsConfigured() {
        let configured = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        let work = codex(id: "codex-work", authPath: "~/.codex-work/auth.json")

        XCTAssertFalse(detectedProviderIsConnected(work, snapshotProviders: [.codex], accounts: [configured]))
    }

    func testExtraCodexHomeMatchesAHandWrittenAccountForTheSameHome() {
        var configured = AccountConfig(id: "work", name: "Work", provider: .codex)
        configured.codexAuthPath = "~/.codex-work/auth.json"
        let work = codex(id: "codex-work", authPath: "~/.codex-work/auth.json")

        XCTAssertTrue(detectedProviderIsConnected(work, snapshotProviders: [.codex], accounts: [configured]))
    }

    func testOtherProvidersStillMatchByProvider() {
        let grok = DetectedProvider(provider: .grok, title: "Grok", detail: "") {
            AccountConfig(id: "grok", name: "Grok", provider: .grok)
        }

        XCTAssertTrue(detectedProviderIsConnected(grok, snapshotProviders: [.grok], accounts: []))
        XCTAssertFalse(detectedProviderIsConnected(grok, snapshotProviders: [.codex], accounts: []))
    }

    private func account(_ id: String, authPath: String?) -> AccountConfig {
        var account = AccountConfig(id: id, name: "Codex", provider: .codex)
        account.codexAuthPath = authPath
        return account
    }

    private func codex(id: String, authPath: String?) -> DetectedProvider {
        DetectedProvider(provider: .codex, title: "Codex", detail: "") {
            var account = AccountConfig(id: id, name: "Codex", provider: .codex)
            account.codexAuthPath = authPath
            return account
        }
    }

    private func makeHome(_ name: String, file: String?) throws {
        try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
        if let file {
            FileManager.default.createFile(atPath: (path(name) as NSString).appendingPathComponent(file), contents: Data())
        }
    }

    private func path(_ name: String) -> String {
        (homeDirectory as NSString).appendingPathComponent(name)
    }
}
