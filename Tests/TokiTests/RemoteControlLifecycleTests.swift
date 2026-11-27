import Combine
import Foundation
import XCTest
@testable import Toki

@MainActor
final class RemoteControlLifecycleTests: XCTestCase {
    private final class FakeProcess: Process, @unchecked Sendable {
        private(set) var runCount = 0
        private(set) var terminateCount = 0
        var isFakeRunning = false
        var exitStatus: Int32 = 0
        var runError: Error?
        private var fakeInput: Any?
        private var fakeOutput: Any?
        private var fakeError: Any?
        private var fakeTerminationHandler: (@Sendable (Process) -> Void)?

        override func run() throws {
            if let runError { throw runError }
            runCount += 1
            isFakeRunning = true
        }

        override func terminate() {
            terminateCount += 1
        }

        override var isRunning: Bool { isFakeRunning }
        override var terminationStatus: Int32 { exitStatus }

        // NSTask's pipe and handler setters are abstract on the base class, so a fake has to
        // store them itself instead of letting the real implementation raise.
        override var standardInput: Any? {
            get { fakeInput }
            set { fakeInput = newValue }
        }

        override var standardOutput: Any? {
            get { fakeOutput }
            set { fakeOutput = newValue }
        }

        override var standardError: Any? {
            get { fakeError }
            set { fakeError = newValue }
        }

        override var terminationHandler: (@Sendable (Process) -> Void)? {
            get { fakeTerminationHandler }
            set { fakeTerminationHandler = newValue }
        }
    }

    // The server hands every process callback to this dispatcher. Holding the work instead of
    // running it lets a test decide exactly when a callback lands, so a stale-callback assertion
    // cannot pass just because the callback has not run yet.
    @MainActor
    private final class CallbackQueue {
        private var pending: [@MainActor () -> Void] = []

        var dispatcher: RemoteControlServer.CallbackDispatcher {
            { [weak self] work in
                MainActor.assumeIsolated { self?.pending.append(work) }
            }
        }

        func runPending() {
            while !pending.isEmpty {
                pending.removeFirst()()
            }
        }
    }

    private struct LaunchFailure: Error {}

    private func makeServer(
        status: RemoteControlServer.TailscaleStatusSnapshot = .init(
            name: nil, diagnostic: nil, cliAvailable: false, serveState: .notServing, serveHost: nil
        ),
        companion: @escaping RemoteControlServer.CompanionProcessFactory,
        tunnel: RemoteControlServer.TunnelProcessFactory? = nil,
        exitWaiter: @escaping RemoteControlServer.ProcessExitWaiter,
        dispatcher: RemoteControlServer.CallbackDispatcher? = nil
    ) -> RemoteControlServer {
        RemoteControlServer(
            tailscaleStatusReader: { _ in status },
            companionProcessFactory: companion,
            tunnelProcessFactory: tunnel,
            processExitWaiter: exitWaiter,
            callbackDispatcher: dispatcher
        )
    }

    private func deviceLine(id: String) -> String {
        """
        devices={"devices": [{"id": "\(id)", "name": "iPhone", "ip": "100.64.0.1", \
        "proxied": false, "paired": 1000, "seen": 1200, "expires": 44200}]}

        """
    }

    private func outputHandler(of process: Process) throws -> (FileHandle) -> Void {
        let pipe = try XCTUnwrap(process.standardOutput as? Pipe)
        return try XCTUnwrap(pipe.fileHandleForReading.readabilityHandler)
    }

    // A closed writer means the handler's `availableData` returns the text or end-of-file, never
    // blocks, and never races the real pipe's own readability handler.
    private func feed(_ text: String, handler: (FileHandle) -> Void) throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        handler(pipe.fileHandleForReading)
    }

    private func readAvailable(_ handle: FileHandle, timeout: TimeInterval = 1) -> Data {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return Data() }
        return handle.availableData
    }

    private func drainAvailable(_ handle: FileHandle) {
        while !readAvailable(handle, timeout: 0.05).isEmpty {}
    }

    func testRestartWaitsForTheOldProcessBeforeLaunching() {
        var created: [FakeProcess] = []
        var waiters: [(Process, @MainActor (Process) -> Void)] = []
        let server = makeServer(
            companion: { _, _, _ in
                let process = FakeProcess()
                created.append(process)
                return process
            },
            exitWaiter: { process, completion in waiters.append((process, completion)) }
        )
        server.hostMode = .localhost

        server.start()
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(server.isRunning)
        XCTAssertFalse(server.isStarting)

        server.restart()
        XCTAssertEqual(created.count, 1, "The replacement must not launch while the old process retires")
        XCTAssertFalse(server.isRunning)
        XCTAssertTrue(server.isStarting)
        XCTAssertEqual(created[0].terminateCount, 1)

        server.start()
        XCTAssertEqual(created.count, 1, "Repeated Start must not bypass the retirement gate")

        XCTAssertEqual(waiters.count, 1)
        waiters[0].1(created[0])

        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].runCount, 1)
        XCTAssertTrue(server.isRunning)
        XCTAssertFalse(server.isStarting)
    }

    func testStopDuringPendingRestartCancelsTheRelaunch() {
        var created: [FakeProcess] = []
        var waiters: [(Process, @MainActor (Process) -> Void)] = []
        let server = makeServer(
            companion: { _, _, _ in
                let process = FakeProcess()
                created.append(process)
                return process
            },
            exitWaiter: { process, completion in waiters.append((process, completion)) }
        )
        server.hostMode = .localhost

        server.start()
        server.restart()
        server.stop()
        XCTAssertFalse(server.isStarting)

        waiters[0].1(created[0])
        XCTAssertEqual(created.count, 1, "Stop must cancel the queued relaunch")
        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(server.isStarting)
    }

    func testStartAfterCancellationQueuesBehindTheSameRetirement() {
        var created: [FakeProcess] = []
        var waiters: [(Process, @MainActor (Process) -> Void)] = []
        let server = makeServer(
            companion: { _, _, _ in
                let process = FakeProcess()
                created.append(process)
                return process
            },
            exitWaiter: { process, completion in waiters.append((process, completion)) }
        )
        server.hostMode = .localhost

        server.start()
        server.restart()
        server.stop()
        server.start()

        XCTAssertEqual(created.count, 1, "Start must wait for the process that is still retiring")
        XCTAssertTrue(server.isStarting)

        waiters[0].1(created[0])
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(server.isRunning)
    }

    func testPendingStartUsesTheHostModeChosenWhileWaiting() {
        var created: [FakeProcess] = []
        var launches: [[String]] = []
        var waiters: [(Process, @MainActor (Process) -> Void)] = []
        let server = makeServer(
            companion: { _, arguments, _ in
                launches.append(arguments)
                let process = FakeProcess()
                created.append(process)
                return process
            },
            exitWaiter: { process, completion in waiters.append((process, completion)) }
        )
        server.hostMode = .localhost

        server.start()
        server.restart()
        server.hostMode = .localNetwork
        waiters[0].1(created[0])

        XCTAssertEqual(created.count, 2)
        let arguments = launches[1]
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--bind")! + 1], "0.0.0.0")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--access")! + 1], "private")
    }

    func testStaleOutputFromAReplacedProcessCannotMutateTheNewServer() throws {
        let queue = CallbackQueue()
        var created: [FakeProcess] = []
        var waiters: [(Process, @MainActor (Process) -> Void)] = []
        let server = makeServer(
            companion: { _, _, _ in
                let process = FakeProcess()
                created.append(process)
                return process
            },
            exitWaiter: { process, completion in waiters.append((process, completion)) },
            dispatcher: queue.dispatcher
        )
        server.hostMode = .localhost

        server.start()
        let oldProcess = created[0]
        let oldHandler = try outputHandler(of: oldProcess)

        server.restart()
        waiters[0].1(oldProcess)
        let newHandler = try outputHandler(of: created[1])

        try feed(deviceLine(id: "new"), handler: newHandler)
        queue.runPending()
        XCTAssertEqual(server.pairedDevices.map(\.id), ["new"])

        try feed(deviceLine(id: "stale"), handler: oldHandler)
        queue.runPending()
        XCTAssertEqual(
            server.pairedDevices.map(\.id),
            ["new"],
            "Output from the replaced process must not reach the new server"
        )
    }

    func testStaleTerminationFromAReplacedProcessCannotStopTheNewServer() throws {
        let queue = CallbackQueue()
        var created: [FakeProcess] = []
        var waiters: [(Process, @MainActor (Process) -> Void)] = []
        let server = makeServer(
            companion: { _, _, _ in
                let process = FakeProcess()
                created.append(process)
                return process
            },
            exitWaiter: { process, completion in waiters.append((process, completion)) },
            dispatcher: queue.dispatcher
        )
        server.hostMode = .localhost

        server.start()
        let oldProcess = created[0]
        let oldTermination = try XCTUnwrap(oldProcess.terminationHandler)

        server.restart()
        waiters[0].1(oldProcess)
        let newInput = try XCTUnwrap(created[1].standardInput as? Pipe)
        drainAvailable(newInput.fileHandleForReading)

        oldTermination(oldProcess)
        queue.runPending()

        XCTAssertTrue(server.isRunning, "A replaced process exiting must not stop the current server")
        server.updateActiveAgents([])
        XCTAssertFalse(
            readAvailable(newInput.fileHandleForReading).isEmpty,
            "The current snapshot pipe must still receive frames"
        )
    }

    func testCurrentTerminationClearsStateAndStopsTheTunnel() throws {
        let queue = CallbackQueue()
        var companions: [FakeProcess] = []
        var tunnels: [FakeProcess] = []
        let server = makeServer(
            companion: { _, _, _ in
                let process = FakeProcess()
                companions.append(process)
                return process
            },
            tunnel: { _, _ in
                let process = FakeProcess()
                tunnels.append(process)
                return process
            },
            exitWaiter: { _, _ in XCTFail("An unexpected exit must not queue a relaunch") },
            dispatcher: queue.dispatcher
        )
        server.hostMode = .tunnel

        server.start()
        XCTAssertEqual(tunnels.count, 1)
        let tunnel = tunnels[0]
        try feed("https://abc.trycloudflare.com\n", handler: outputHandler(of: tunnel))
        queue.runPending()
        XCTAssertEqual(server.tunnelHost, "abc.trycloudflare.com")

        let termination = try XCTUnwrap(companions[0].terminationHandler)
        companions[0].exitStatus = 1
        termination(companions[0])
        queue.runPending()

        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.tunnelHost)
        XCTAssertEqual(tunnel.terminateCount, 1, "The companion exiting must stop its tunnel")
        XCTAssertEqual(server.lastError, "The remote control server stopped (exit code 1).")
    }

    func testFailedLaunchReportsAnErrorWithoutLeavingPendingStart() {
        let server = makeServer(
            companion: { _, _, _ in throw LaunchFailure() },
            exitWaiter: { _, _ in }
        )
        server.hostMode = .localhost

        server.start()

        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(server.isStarting)
        XCTAssertEqual(
            server.lastError,
            "Could not launch Python 3. Install it (xcode-select --install) and try again."
        )
    }

    func testUnchangedTailscaleSkipStateDoesNotRepublish() async {
        let queue = CallbackQueue()
        let conflict = RemoteControlServer.TailscaleStatusSnapshot(
            name: "mac.example.ts.net", diagnostic: "Connected", cliAvailable: true,
            serveState: .conflict, serveHost: nil
        )
        let server = makeServer(
            status: conflict,
            companion: { _, _, _ in FakeProcess() },
            exitWaiter: { _, _ in },
            dispatcher: queue.dispatcher
        )
        server.hostMode = .localhost
        server.companionAppMode = .hosted
        server.start()
        XCTAssertTrue(server.isRunning)
        await server.refreshTailscaleStatus().value
        XCTAssertNotNil(server.autoServeSkipped)

        var publications = 0
        let observation = server.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        await server.refreshTailscaleStatus().value
        XCTAssertEqual(publications, 0, "An unchanged skip state must not republish")
    }

    func testTunnelCallbacksBelongToTheirOwningServer() throws {
        let firstQueue = CallbackQueue()
        let secondQueue = CallbackQueue()
        var tunnelsA: [FakeProcess] = []
        var tunnelsB: [FakeProcess] = []
        let first = makeServer(
            companion: { _, _, _ in FakeProcess() },
            tunnel: { _, _ in
                let process = FakeProcess()
                tunnelsA.append(process)
                return process
            },
            exitWaiter: { _, _ in },
            dispatcher: firstQueue.dispatcher
        )
        let second = makeServer(
            companion: { _, _, _ in FakeProcess() },
            tunnel: { _, _ in
                let process = FakeProcess()
                tunnelsB.append(process)
                return process
            },
            exitWaiter: { _, _ in },
            dispatcher: secondQueue.dispatcher
        )

        first.startTunnel()
        second.startTunnel()
        try feed("https://first.trycloudflare.com\n", handler: outputHandler(of: tunnelsA[0]))
        firstQueue.runPending()

        XCTAssertEqual(first.tunnelHost, "first.trycloudflare.com")
        XCTAssertNil(second.tunnelHost, "A tunnel must publish to the server that owns it")
    }

    func testStaleTunnelOutputAndExitAreIgnoredAfterReplacement() throws {
        let queue = CallbackQueue()
        var tunnels: [FakeProcess] = []
        let server = makeServer(
            companion: { _, _, _ in FakeProcess() },
            tunnel: { _, _ in
                let process = FakeProcess()
                tunnels.append(process)
                return process
            },
            exitWaiter: { _, _ in },
            dispatcher: queue.dispatcher
        )
        server.hostMode = .tunnel

        server.startTunnel()
        let oldTunnel = tunnels[0]
        let oldHandler = try outputHandler(of: oldTunnel)
        let oldTermination = try XCTUnwrap(oldTunnel.terminationHandler)

        server.stopTunnel()
        server.startTunnel()
        let newHandler = try outputHandler(of: tunnels[1])

        // The replacement has not published its URL yet, so only the ownership guard can reject
        // this. The `tunnelHost == nil` check alone would accept it.
        try feed("https://stale.trycloudflare.com\n", handler: oldHandler)
        queue.runPending()
        XCTAssertNil(server.tunnelHost, "Output from a replaced tunnel must be ignored")

        try feed("https://new.trycloudflare.com\n", handler: newHandler)
        queue.runPending()
        XCTAssertEqual(server.tunnelHost, "new.trycloudflare.com")

        oldTermination(oldTunnel)
        queue.runPending()
        XCTAssertEqual(server.tunnelHost, "new.trycloudflare.com")
        XCTAssertFalse(server.isStartingTunnel)
    }
}
