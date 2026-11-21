import Foundation
import Darwin

struct JSONRPCResponse {
    let result: Any?
    let error: [String: Any]?
}

final class CLIJSONProcess {
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    static func run<Value: Sendable>(_ work: @escaping @Sendable (Cancellation) throws -> Value) async throws -> Value {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        return try work(cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func makeWorkspace() throws -> (URL, [String: String]) {
        // A short path leaves room for Grok's Unix-domain socket name on macOS.
        let workspace = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("toki-usage-\(UUID().uuidString)", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            // A scheduled background check must not open an OAuth flow.
            for name in ["open", "xdg-open"] {
                let url = workspace.appendingPathComponent(name)
                try "#!/bin/sh\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        } catch {
            try? files.removeItem(at: workspace)
            throw error
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(workspace.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["BROWSER"] = workspace.appendingPathComponent("open").path
        return (workspace, environment)
    }

    private let label: String
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let cancellation: Cancellation
    private var buffer = Data()
    private var isClosed = false

    private static let maximumOutputSize = 1024 * 1024

    init(process: Process, label: String, cancellation: Cancellation) throws {
        try cancellation.check()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        self.process = process
        self.label = label
        self.cancellation = cancellation
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(output.fileDescriptor, F_SETFL, O_NONBLOCK)
    }

    func request(id: Int, method: String, params: String, timeout: TimeInterval) throws -> JSONRPCResponse {
        guard !isClosed, process.isRunning else {
            throw LocalizedErrorMessage("\(label) stopped before replying")
        }
        try write(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
        return try readResponse(id: id, timeout: timeout)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? input.close()
        try? output.close()
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
    }

    deinit {
        close()
    }

    func write(_ line: String) throws {
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    private func readResponse(id: Int, timeout: TimeInterval) throws -> JSONRPCResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancellation.check()
            while let line = nextLine() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                guard json["id"] as? Int == id else { continue }
                return JSONRPCResponse(result: json["result"], error: json["error"] as? [String: Any])
            }

            guard let chunk = try readChunk(deadline: deadline) else { break }
            buffer.append(chunk)
            guard buffer.count <= Self.maximumOutputSize else {
                throw LocalizedErrorMessage("\(label) returned too much output")
            }
        }
        throw LocalizedErrorMessage("\(label) timed out before replying")
    }

    func readOutput(timeout: TimeInterval) throws -> Data {
        try input.close()
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while let chunk = try readChunk(deadline: deadline) {
            data.append(chunk)
            guard data.count <= Self.maximumOutputSize else {
                throw LocalizedErrorMessage("\(label) returned too much output")
            }
        }
        while process.isRunning && Date() < deadline {
            try cancellation.check()
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw LocalizedErrorMessage("\(label) did not complete successfully")
        }
        return data
    }

    private func readChunk(deadline: Date) throws -> Data? {
        while Date() < deadline {
            try cancellation.check()
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = min(250, max(1, Int(deadline.timeIntervalSinceNow * 1_000)))
            let ready = Darwin.poll(&descriptor, 1, Int32(milliseconds))
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { break }

            var chunk = Data(count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk.count = count
                return chunk
            }
            if count == 0 { return nil }
            if errno != EAGAIN && errno != EINTR { break }
        }
        throw LocalizedErrorMessage(Date() >= deadline
            ? "\(label) timed out before replying"
            : "\(label) output could not be read")
    }

    private func nextLine() -> String? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = String(data: buffer[..<newline], encoding: .utf8)
        buffer.removeSubrange(...newline)
        return line
    }
}
