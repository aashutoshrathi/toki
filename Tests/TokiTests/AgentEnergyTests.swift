import Combine
import XCTest
@testable import Toki

@MainActor
private final class AgentScanProbe {
    var results: [[ActiveAgent]]
    private var continuations: [CheckedContinuation<[ActiveAgent], Never>] = []
    private(set) var scanCount = 0
    var onScan: ((Int) -> Void)?

    init(results: [[ActiveAgent]] = []) {
        self.results = results
    }

    func scan() async -> [ActiveAgent] {
        scanCount += 1
        onScan?(scanCount)
        if !results.isEmpty {
            return results.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func finishNext(with agents: [ActiveAgent]) {
        guard !continuations.isEmpty else {
            XCTFail("No controlled agent scan is waiting")
            return
        }
        continuations.removeFirst().resume(returning: agents)
    }
}

@MainActor
private final class AgentRemoteProbe {
    var isRunning = false
}

@MainActor
final class AgentEnergyTests: XCTestCase {
    private var stores: [UsageStore] = []

    override func tearDown() async throws {
        await MainActor.run {
            for store in stores {
                store.timer?.invalidate()
                store.agentTimer?.invalidate()
                store.agentRemoteControlCancellable?.cancel()
            }
            stores.removeAll()
        }
        try await super.tearDown()
    }

    private func agent(_ id: Int32, needsInput: Bool = false) -> ActiveAgent {
        ActiveAgent(
            id: id, provider: .claudeCode, directory: nil, chatTitle: "Agent \(id)",
            hostApp: nil, hostProcessID: nil, lastActivity: nil, processID: id, runtime: "1:00",
            terminalTTY: nil, memoryKB: 1000, command: "claude", sessionUsage: nil,
            attention: needsInput ? AgentAttention(kind: .question, prompt: "Continue?") : nil
        )
    }

    private func store(
        results: [[ActiveAgent]],
        remote: AgentRemoteProbe = AgentRemoteProbe()
    ) -> (UsageStore, AgentScanProbe, AgentRemoteProbe) {
        let scanner = AgentScanProbe(results: results)
        let store = UsageStore(
            agentScan: { await scanner.scan() },
            agentRemoteControlIsRunning: { remote.isRunning },
            startsAutomatically: false
        )
        stores.append(store)
        store.scheduleAgentRefresh()
        store.refreshActiveAgents()
        return (store, scanner, remote)
    }

    private func waitForScan(_ scanner: AgentScanProbe, count: Int) async {
        if scanner.scanCount >= count { return }
        let started = expectation(description: "Agent scan \(count) started")
        scanner.onScan = { if $0 == count { started.fulfill() } }
        await fulfillment(of: [started], timeout: 1)
        scanner.onScan = nil
    }

    private func waitForIdle(_ store: UsageStore) async {
        if !store.isScanningAgents { return }
        let finished = expectation(description: "Agent scan finished")
        var observation: AnyCancellable?
        observation = store.$isScanningAgents.sink { scanning in
            if !scanning {
                finished.fulfill()
                observation?.cancel()
            }
        }
        await fulfillment(of: [finished], timeout: 1)
        observation?.cancel()
    }

    func testHiddenIdleUsesSixtySecondsAndOpenScansImmediatelyAtFifteen() async {
        let (store, scanner, _) = store(results: [[], []])
        await waitForIdle(store)
        XCTAssertEqual(store.agentTimer?.timeInterval, 60)

        store.setAgentPopoverVisible(true)
        XCTAssertEqual(store.agentTimer?.timeInterval, 15)
        await waitForScan(scanner, count: 2)
        await waitForIdle(store)
        XCTAssertEqual(scanner.scanCount, 2, "Opening must not wait for the repeating timer")

        let visibleTimer = store.agentTimer
        store.setAgentPopoverVisible(true)
        XCTAssertTrue(store.agentTimer === visibleTimer, "A duplicate open must not reset the timer")
        XCTAssertEqual(scanner.scanCount, 2, "Only the visibility transition triggers an open scan")

        store.setAgentPopoverVisible(false)
        XCTAssertEqual(store.agentTimer?.timeInterval, 60)
    }

    func testNeedsInputAndRemoteTransitionsControlTheHiddenInterval() async {
        let (store, scanner, remote) = store(results: [[agent(1, needsInput: true)]])
        await waitForIdle(store)
        XCTAssertEqual(store.agentTimer?.timeInterval, 15)

        let attentionTimer = store.agentTimer
        store.setAgentPopoverVisible(true)
        XCTAssertTrue(store.agentTimer === attentionTimer, "Already-frequent polling must not restart")
        scanner.results = [[agent(1)]]
        await waitForScan(scanner, count: 2)
        await waitForIdle(store)
        store.setAgentPopoverVisible(false)
        XCTAssertEqual(store.agentTimer?.timeInterval, 60)

        remote.isRunning = true
        store.scheduleAgentRefresh()
        XCTAssertEqual(store.agentTimer?.timeInterval, 15)
        let remoteTimer = store.agentTimer
        store.scheduleAgentRefresh()
        XCTAssertTrue(store.agentTimer === remoteTimer, "An unchanged remote state must not reset the timer")

        remote.isRunning = false
        store.scheduleAgentRefresh()
        XCTAssertEqual(store.agentTimer?.timeInterval, 60)
    }

    func testTimerTickSkipsDuringScanAndManualRequestsQueueOneFollowUp() async {
        let (store, scanner, _) = store(results: [[]])
        await waitForIdle(store)

        // Exercise the timer callback once and wait until its queued MainActor work has started.
        store.agentTimer?.fire()
        await waitForScan(scanner, count: 2)
        // A timer request while the scan is blocked must be ignored synchronously. Avoid queuing
        // another timer Task whose scheduling order would be independent of the controlled scan.
        store.refreshActiveAgents(manual: false)
        store.refreshActiveAgents()
        store.refreshActiveAgents()
        XCTAssertTrue(store.agentRefreshAfterCurrent)

        scanner.results = [[]]
        scanner.finishNext(with: [])
        await waitForScan(scanner, count: 3)
        await waitForIdle(store)
        XCTAssertEqual(scanner.scanCount, 3, "Two manual requests coalesce; timer ticks never queue")
        XCTAssertFalse(store.agentRefreshAfterCurrent)
        XCTAssertFalse(store.isScanningAgents)
    }

    func testOptedOutInitializationHasNoAutomaticStartupWork() async {
        let scanner = AgentScanProbe(results: [[]])
        var remoteProbeCalls = 0
        let store = UsageStore(
            agentScan: { await scanner.scan() },
            agentRemoteControlIsRunning: { remoteProbeCalls += 1; return false },
            startsAutomatically: false
        )
        stores.append(store)
        XCTAssertEqual(scanner.scanCount, 0)
        XCTAssertEqual(remoteProbeCalls, 0)
        XCTAssertNil(store.timer)
        XCTAssertNil(store.agentTimer)
        XCTAssertNil(store.config)
        XCTAssertNil(store.agentRemoteControlCancellable)
        XCTAssertNil(store.providerScanTask)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(store.isScanningProviders)

        store.scheduleAgentRefresh()
        store.refreshActiveAgents()
        await waitForScan(scanner, count: 1)
        XCTAssertEqual(scanner.scanCount, 1)
        await waitForIdle(store)
    }

    func testUnchangedResultsDoNotPublishRegardlessOfVisibilityAndCompleteArrayChangesDo() async {
        let initial = [agent(1, needsInput: true), agent(2)]
        let (store, scanner, _) = store(results: [initial])
        await waitForIdle(store)

        var publications = 0
        let observation = store.$activeAgents.dropFirst().sink { _ in publications += 1 }
        scanner.results = [initial]
        store.agentTimer?.fire()
        await waitForScan(scanner, count: 2)
        await waitForIdle(store)
        XCTAssertEqual(publications, 0, "An unchanged hidden result must not publish")

        // The needs-input count stays one. Comparing only that count would drop this update.
        let changed = [agent(1), agent(2, needsInput: true)]
        scanner.results = [changed]
        let attentionTimer = store.agentTimer
        store.agentTimer?.fire()
        await waitForScan(scanner, count: 3)
        await waitForIdle(store)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.activeAgents, changed)
        XCTAssertTrue(store.agentTimer === attentionTimer, "Still needing input must not reset the timer")

        scanner.results = [changed]
        store.setAgentPopoverVisible(true)
        await waitForScan(scanner, count: 4)
        await waitForIdle(store)
        XCTAssertEqual(publications, 1, "A visible unchanged result must not publish")

        scanner.results = [initial]
        store.refreshActiveAgents()
        await waitForScan(scanner, count: 5)
        await waitForIdle(store)
        XCTAssertEqual(publications, 2, "A visible complete-array change must publish")
        XCTAssertEqual(store.activeAgents, initial)
        observation.cancel()
    }
}
