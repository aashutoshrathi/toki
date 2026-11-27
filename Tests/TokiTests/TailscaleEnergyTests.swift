import Combine
import XCTest
@testable import Toki

@MainActor
final class TailscaleEnergyTests: XCTestCase {
    func testHiddenAndVisibleIrrelevantSettingsRefreshOnlyOnEntry() {
        let ticks = PassthroughSubject<Void, Never>()
        var refreshCount = 0
        let polling = TailscaleStatusPollingController(timer: ticks.eraseToAnyPublisher()) { refreshCount += 1 }
        polling.update(isVisible: false, isRelevant: true)
        polling.update(isVisible: true, isRelevant: false)
        polling.update(isVisible: true, isRelevant: false)
        ticks.send(())
        XCTAssertEqual(refreshCount, 1)
        polling.update(isVisible: false, isRelevant: false)
        polling.update(isVisible: true, isRelevant: false)
        XCTAssertEqual(refreshCount, 2)
    }

    func testPollingVisibilityAndRelevanceTransitions() {
        let ticks = PassthroughSubject<Void, Never>()
        var refreshCount = 0
        let polling = TailscaleStatusPollingController(timer: ticks.eraseToAnyPublisher()) { refreshCount += 1 }
        polling.update(isVisible: true, isRelevant: true)
        polling.update(isVisible: true, isRelevant: true)
        ticks.send(())
        XCTAssertEqual(refreshCount, 2)
        polling.update(isVisible: true, isRelevant: false)
        ticks.send(())
        XCTAssertEqual(refreshCount, 2)
        polling.update(isVisible: true, isRelevant: true)
        XCTAssertEqual(refreshCount, 3)
        polling.stop()
        polling.update(isVisible: true, isRelevant: true)
        ticks.send(())
        XCTAssertEqual(refreshCount, 5)
        polling.update(isVisible: false, isRelevant: true)
        ticks.send(())
        XCTAssertEqual(refreshCount, 5)
    }

    func testConcurrentRefreshesShareOneStatusRead() async {
        var readCount = 0
        var continuations: [CheckedContinuation<RemoteControlServer.TailscaleStatusSnapshot, Never>] = []
        var entries: [XCTestExpectation] = []
        let server = RemoteControlServer(tailscaleStatusReader: { _ in
            readCount += 1
            if !entries.isEmpty { entries.removeFirst().fulfill() }
            return await withCheckedContinuation { continuations.append($0) }
        })
        let entered = expectation(description: "first status read entered")
        entries.append(entered)
        let first = server.refreshTailscaleStatus()
        let concurrent = server.refreshTailscaleStatus()
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(readCount, 1)
        guard !continuations.isEmpty else { XCTFail("reader continuation missing"); return }
        continuations.removeFirst().resume(returning: snapshot())
        await first.value
        await concurrent.value
        let laterEntered = expectation(description: "later status read entered")
        entries.append(laterEntered)
        let later = server.refreshTailscaleStatus()
        await fulfillment(of: [laterEntered], timeout: 1)
        XCTAssertEqual(readCount, 2)
        guard !continuations.isEmpty else { XCTFail("later continuation missing"); return }
        continuations.removeFirst().resume(returning: snapshot())
        await later.value
    }

    func testExplicitRefreshCoalescesOneTrailingReadAndWaitsForIt() async {
        var readCount = 0
        var continuations: [CheckedContinuation<RemoteControlServer.TailscaleStatusSnapshot, Never>] = []
        var entries: [XCTestExpectation] = []
        let server = RemoteControlServer(tailscaleStatusReader: { _ in
            readCount += 1
            if !entries.isEmpty { entries.removeFirst().fulfill() }
            return await withCheckedContinuation { continuations.append($0) }
        })
        let firstEntry = expectation(description: "first read entered")
        entries.append(firstEntry)
        let task = server.refreshTailscaleStatus()
        await fulfillment(of: [firstEntry], timeout: 1)
        let trailingEntry = expectation(description: "trailing read entered")
        entries.append(trailingEntry)
        _ = server.refreshTailscaleStatus(recheckAfterCurrent: true)
        _ = server.refreshTailscaleStatus(recheckAfterCurrent: true)
        guard !continuations.isEmpty else { XCTFail("first continuation missing"); return }
        continuations.removeFirst().resume(returning: snapshot(name: "stale.example.ts.net"))
        await fulfillment(of: [trailingEntry], timeout: 1)
        XCTAssertNil(server.tailscaleDNSName, "Superseded status must not publish")
        XCTAssertEqual(readCount, 2)
        guard !continuations.isEmpty else { XCTFail("trailing continuation missing"); return }
        continuations.removeFirst().resume(returning: snapshot(name: "fresh.example.ts.net"))
        await task.value
        XCTAssertEqual(server.tailscaleDNSName, "fresh.example.ts.net")

        let laterEntry = expectation(description: "later ordinary read entered")
        entries.append(laterEntry)
        let later = server.refreshTailscaleStatus()
        await fulfillment(of: [laterEntry], timeout: 1)
        XCTAssertEqual(readCount, 3)
        guard !continuations.isEmpty else { XCTFail("later continuation missing"); return }
        continuations.removeFirst().resume(returning: snapshot())
        await later.value
    }

    func testCancelledRefreshDoesNotPublishOrClearItsReplacement() async {
        var continuations: [CheckedContinuation<RemoteControlServer.TailscaleStatusSnapshot, Never>] = []
        var entries: [XCTestExpectation] = []
        let server = RemoteControlServer(tailscaleStatusReader: { _ in
            if !entries.isEmpty { entries.removeFirst().fulfill() }
            return await withCheckedContinuation { continuations.append($0) }
        })
        let oldEntry = expectation(description: "old read entered")
        entries.append(oldEntry)
        let cancelled = server.refreshTailscaleStatus()
        await fulfillment(of: [oldEntry], timeout: 1)
        cancelled.cancel()
        let newEntry = expectation(description: "replacement read entered")
        entries.append(newEntry)
        let replacement = server.refreshTailscaleStatus()
        await fulfillment(of: [newEntry], timeout: 1)
        let replacementTrailingEntry = expectation(description: "replacement trailing read entered")
        entries.append(replacementTrailingEntry)
        _ = server.refreshTailscaleStatus(recheckAfterCurrent: true)
        guard continuations.count == 2 else { XCTFail("expected old and replacement reads"); return }
        continuations.removeFirst().resume(returning: snapshot(name: "stale.example.ts.net"))
        await cancelled.value
        XCTAssertNil(server.tailscaleDNSName)
        guard continuations.count == 1 else {
            XCTFail("Old cleanup must not clear replacement task")
            return
        }
        continuations.removeFirst().resume(returning: snapshot(name: "fresh.example.ts.net"))
        await fulfillment(of: [replacementTrailingEntry], timeout: 1)
        guard continuations.count == 1 else {
            XCTFail("Replacement must preserve its pending recheck")
            return
        }
        continuations.removeFirst().resume(returning: snapshot(name: "newest.example.ts.net"))
        await replacement.value
        XCTAssertEqual(server.tailscaleDNSName, "newest.example.ts.net")
    }

    func testUnchangedStatusDoesNotRepublishReachabilityProperties() async {
        let server = RemoteControlServer(tailscaleStatusReader: { _ in self.snapshot() })
        var publicationCount = 0
        let observation = server.objectWillChange.sink { publicationCount += 1 }
        defer { observation.cancel() }
        await server.refreshTailscaleStatus().value
        XCTAssertEqual(publicationCount, 4)
        await server.refreshTailscaleStatus().value
        XCTAssertEqual(publicationCount, 4)
    }

    private func snapshot(name: String? = "mac.example.ts.net") -> RemoteControlServer.TailscaleStatusSnapshot {
        .init(name: name, diagnostic: "Connected", cliAvailable: true, serveState: .ready, serveHost: nil)
    }
}
