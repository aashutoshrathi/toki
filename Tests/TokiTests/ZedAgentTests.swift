import Foundation
import XCTest
@testable import Toki

@MainActor
final class ZedAgentTests: XCTestCase {
    private func thread(
        agent: String = "",
        title: String? = "Fix the parser",
        updated: Date? = Date(),
        directory: String? = "/tmp/project"
    ) -> ZedThreadStore.Thread {
        ZedThreadStore.Thread(agentName: agent, title: title, updated: updated, directory: directory)
    }

    private let psOutput = """
    401 1 ?? 04:11 91234 /Applications/Zed.app/Contents/MacOS/zed
    900 401 ?? 00:31 41000 /opt/homebrew/bin/node /Users/x/Library/Application Support/Zed/external_agents/claude-code-acp/0.12.6/node_modules/@zed-industries/claude-code-acp/dist/index.js
    """

    // MARK: - Thread store rows

    func testThreadRowParsesFieldsSeparatedByUnitSeparator() {
        let row = Substring("Claude Code\u{1f}Fix the parser\u{1f}2026-09-08T10:00:00Z\u{1f}/Users/x/git/toki")
        let parsed = ZedThreadStore.parse(row: row)
        XCTAssertEqual(parsed?.agentName, "Claude Code")
        XCTAssertEqual(parsed?.title, "Fix the parser")
        XCTAssertEqual(parsed?.directory, "/Users/x/git/toki")
        XCTAssertEqual(parsed?.isNative, false)
    }

    func testThreadRowWithoutAnAgentIsZedsOwn() {
        let row = Substring("\u{1f}\u{1f}2026-09-08T10:00:00Z\u{1f}/Users/x/git/toki")
        let parsed = ZedThreadStore.parse(row: row)
        XCTAssertEqual(parsed?.isNative, true)
        XCTAssertEqual(parsed?.displayAgentName, "Zed Agent")
        // An empty title is a thread Zed has not summarised yet, not a title of "".
        XCTAssertNil(parsed?.title)
    }

    func testShortRowIsRejectedRatherThanReadAsPartialFields() {
        XCTAssertNil(ZedThreadStore.parse(row: Substring("Claude Code\u{1f}Fix the parser")))
    }

    func testRelativeDirectoryIsDroppedRatherThanTrusted() {
        let row = Substring("\u{1f}Title\u{1f}2026-09-08T10:00:00Z\u{1f}not-a-path")
        XCTAssertNil(ZedThreadStore.parse(row: row)?.directory)
    }

    func testTimestampsParseWithAndWithoutFractionalSeconds() {
        XCTAssertEqual(
            ZedThreadStore.date(fromRFC3339: "2026-09-08T10:00:00Z"),
            Date(timeIntervalSince1970: 1_788_861_600)
        )
        XCTAssertNotNil(ZedThreadStore.date(fromRFC3339: "2026-09-08T10:00:00.123Z"))
        XCTAssertNil(ZedThreadStore.date(fromRFC3339: ""))
        XCTAssertNil(ZedThreadStore.date(fromRFC3339: "yesterday"))
    }

    func testThreadForDirectoryMatchesTheRecordedProjectFolder() {
        let threads = [thread(directory: "/tmp/other"), thread(title: "Wanted", directory: "/tmp/project")]
        XCTAssertEqual(ZedThreadStore.thread(forDirectory: "/tmp/project", in: threads)?.title, "Wanted")
        XCTAssertNil(ZedThreadStore.thread(forDirectory: "/tmp/elsewhere", in: threads))
    }

    // MARK: - Process classification

    func testZedApplicationIsRecognisedOnEveryChannel() {
        XCTAssertTrue(ActiveAgentScanner.isZedApplication(command: "/Applications/Zed.app/Contents/MacOS/zed"))
        XCTAssertTrue(ActiveAgentScanner.isZedApplication(command: "/Applications/Zed Preview.app/Contents/MacOS/zed ."))
        XCTAssertFalse(ActiveAgentScanner.isZedApplication(command: "/Applications/Zed.app/Contents/MacOS/zed-helper"))
        XCTAssertFalse(ActiveAgentScanner.isZedApplication(command: "/usr/local/bin/zed"))
    }

    func testZedApplicationPIDComesFromTheScanWeAlreadyRan() {
        XCTAssertEqual(ActiveAgentScanner.zedApplicationPID(psOutput: psOutput), 401)
        XCTAssertNil(ActiveAgentScanner.zedApplicationPID(psOutput: "401 1 ?? 04:11 91234 /bin/zsh"))
    }

    func testSyntheticIdentifiersAreStableAndNeverCollideWithAPID() {
        let first = ActiveAgentScanner.syntheticID(for: "/tmp/project")
        XCTAssertEqual(first, ActiveAgentScanner.syntheticID(for: "/tmp/project"))
        XCTAssertNotEqual(first, ActiveAgentScanner.syntheticID(for: "/tmp/other"))
        XCTAssertLessThan(first, 0)
    }

    // MARK: - Threads with no process

    func testNativeThreadBecomesARowWithNoProcessBehindIt() {
        let agents = ActiveAgentScanner.zedThreadAgents(
            alongside: [],
            psOutput: psOutput,
            threads: [thread(title: "Sketch the widget")],
            now: Date()
        )
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].provider, .zed)
        XCTAssertEqual(agents[0].chatTitle, "Sketch the widget")
        XCTAssertEqual(agents[0].hostApp, HostApp.zed)
        XCTAssertEqual(agents[0].hostProcessID, 401)
        XCTAssertEqual(agents[0].origin, .threadStore)
        // Nothing to signal, and the only real PID nearby is the editor's.
        XCTAssertFalse(agents[0].canTerminate)
        XCTAssertLessThan(agents[0].processID, 0)
    }

    func testThreadRunByAnAcpServerIsLeftToThatProcess() {
        let running = ActiveAgent(
            id: 900,
            provider: .zed,
            directory: "/tmp/project",
            chatTitle: "Fix the parser",
            hostApp: HostApp.zed,
            hostProcessID: 401,
            lastActivity: Date(),
            processID: 900,
            runtime: "00:31",
            terminalTTY: nil,
            memoryKB: 41_000,
            command: "node index.js",
            sessionUsage: nil,
            attention: nil
        )
        let agents = ActiveAgentScanner.zedThreadAgents(
            alongside: [running],
            psOutput: psOutput,
            threads: [thread(directory: "/tmp/project")],
            now: Date()
        )
        XCTAssertTrue(agents.isEmpty)
    }

    func testAThreadZedRunsItselfIsTheOnlyKindWithoutAProcess() {
        let agents = ActiveAgentScanner.zedThreadAgents(
            alongside: [],
            psOutput: psOutput,
            threads: [thread(agent: "Claude Code")],
            now: Date()
        )
        XCTAssertTrue(agents.isEmpty)
    }

    func testAThreadNobodyHasTouchedInHalfAnHourIsNotALiveSession() {
        let now = Date()
        let stale = now.addingTimeInterval(-ActiveAgentScanner.zedThreadActivityWindow - 60)
        XCTAssertTrue(
            ActiveAgentScanner.zedThreadAgents(
                alongside: [], psOutput: psOutput, threads: [thread(updated: stale)], now: now
            ).isEmpty
        )
        XCTAssertTrue(
            ActiveAgentScanner.zedThreadAgents(
                alongside: [], psOutput: psOutput, threads: [thread(updated: nil)], now: now
            ).isEmpty
        )
    }

    func testOnlyTheNewestThreadInAFolderIsShown() {
        let now = Date()
        let threads = [
            thread(title: "Older", updated: now.addingTimeInterval(-60), directory: "/tmp/project"),
            thread(title: "Newest", updated: now, directory: "/tmp/project")
        ]
        let agents = ActiveAgentScanner.zedThreadAgents(
            alongside: [], psOutput: psOutput, threads: threads, now: now
        )
        XCTAssertEqual(agents.map(\.chatTitle), ["Newest"])
    }

    func testNothingIsShownWhenZedIsNotRunning() {
        XCTAssertTrue(
            ActiveAgentScanner.zedThreadAgents(
                alongside: [], psOutput: "401 1 ?? 04:11 91234 /bin/zsh", threads: [thread()], now: Date()
            ).isEmpty
        )
    }

    // MARK: - Wiring

    func testZedIsPublishedToRemoteControlUnderItsOwnName() {
        XCTAssertEqual(RemoteControlServer.remoteProviderName(for: .zed), "zed")
    }

    func testZedIsNotConsumerTracked() {
        XCTAssertEqual(Provider.zed.displayName, "Zed")
        XCTAssertFalse(Provider.zed.isConsumerTracked)
    }
}
