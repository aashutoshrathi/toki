import Combine
import XCTest
@testable import Toki

@MainActor
final class TailscaleEnergyTests: XCTestCase {
    func testHiddenOrIrrelevantSettingsNeverRefreshTailscale() {
        let ticks = PassthroughSubject<Void, Never>()
        var refreshCount = 0
        let polling = TailscaleStatusPollingController(
            timer: ticks.eraseToAnyPublisher(),
            refresh: { refreshCount += 1 }
        )

        polling.update(isVisible: false, isRelevant: true)
        polling.update(isVisible: true, isRelevant: false)
        ticks.send(())

        XCTAssertEqual(refreshCount, 0)
    }

    func testPollingStopsAndRestartsAcrossVisibilityChanges() {
        let ticks = PassthroughSubject<Void, Never>()
        var refreshCount = 0
        let polling = TailscaleStatusPollingController(
            timer: ticks.eraseToAnyPublisher(),
            refresh: { refreshCount += 1 }
        )

        polling.update(isVisible: true, isRelevant: true)
        polling.update(isVisible: true, isRelevant: true)
        ticks.send(())
        XCTAssertEqual(refreshCount, 2)

        polling.update(isVisible: false, isRelevant: true)
        ticks.send(())
        XCTAssertEqual(refreshCount, 2)

        polling.update(isVisible: true, isRelevant: true)
        ticks.send(())
        XCTAssertEqual(refreshCount, 4)
    }

    func testConcurrentRefreshesShareOneStatusRead() async {
        var readCount = 0
        var continuations: [CheckedContinuation<RemoteControlServer.TailscaleStatusSnapshot, Never>] = []
        let server = RemoteControlServer(tailscaleStatusReader: { _ in
            readCount += 1
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        })

        let first = server.refreshTailscaleStatus()
        let concurrent = server.refreshTailscaleStatus()
        await Task.yield()
        XCTAssertEqual(readCount, 1)

        continuations[0].resume(returning: snapshot())
        await first.value
        await concurrent.value

        let afterCompletion = server.refreshTailscaleStatus()
        await Task.yield()
        XCTAssertEqual(readCount, 2)
        continuations[1].resume(returning: snapshot())
        await afterCompletion.value
    }

    func testCancelledRefreshDoesNotPublishOrClearItsReplacement() async {
        var continuations: [CheckedContinuation<RemoteControlServer.TailscaleStatusSnapshot, Never>] = []
        let server = RemoteControlServer(tailscaleStatusReader: { _ in
            await withCheckedContinuation { continuations.append($0) }
        })

        let cancelled = server.refreshTailscaleStatus()
        await Task.yield()
        XCTAssertEqual(continuations.count, 1)
        cancelled.cancel()

        let replacement = server.refreshTailscaleStatus()
        await Task.yield()
        XCTAssertEqual(continuations.count, 2)

        continuations[0].resume(returning: snapshot(name: "stale.example.ts.net"))
        await cancelled.value
        XCTAssertNil(server.tailscaleDNSName)

        let concurrent = server.refreshTailscaleStatus()
        await Task.yield()
        XCTAssertEqual(continuations.count, 2, "Old cleanup must not clear the replacement task")

        continuations[1].resume(returning: snapshot(name: "fresh.example.ts.net"))
        await replacement.value
        await concurrent.value
        XCTAssertEqual(server.tailscaleDNSName, "fresh.example.ts.net")
    }

    func testUnchangedStatusDoesNotRepublishReachabilityProperties() async {
        let server = RemoteControlServer(tailscaleStatusReader: { _ in
            self.snapshot()
        })
        var publicationCount = 0
        let observation = server.objectWillChange.sink {
            publicationCount += 1
        }
        defer { observation.cancel() }

        await server.refreshTailscaleStatus().value
        XCTAssertEqual(publicationCount, 4)

        await server.refreshTailscaleStatus().value
        XCTAssertEqual(publicationCount, 4)
    }

    private func snapshot(name: String? = "mac.example.ts.net") -> RemoteControlServer.TailscaleStatusSnapshot {
        RemoteControlServer.TailscaleStatusSnapshot(
            name: name,
            diagnostic: "Connected",
            cliAvailable: true,
            serveState: .ready,
            serveHost: nil
        )
    }
}
