import Foundation
import Darwin

struct CodexRPCResponse {
    let result: Any?
    let error: [String: Any]?
}

protocol CodexAppServerSession: AnyObject {
    func request(id: Int, method: String, params: String, timeout: TimeInterval) throws -> CodexRPCResponse
    func close()
}

final class CodexAppServerProcessSession: CodexAppServerSession {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()
    private var isClosed = false

    init(account: AccountConfig, binary: CodexBinary, path: String) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = CodexAppServerClient.codexHomeDirectory(for: account)
        let expandedSearchPath = path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        environment["PATH"] = "\(expandedSearchPath):\(environment["PATH"] ?? "")"
        process.executableURL = URL(fileURLWithPath: binary.executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        _ = fcntl(output.fileDescriptor, F_SETFL, O_NONBLOCK)

        do {
            let initialized = try request(
                id: 1,
                method: "initialize",
                params: #"{"clientInfo":{"name":"Toki","version":"\#(appVersion)"},"capabilities":{"experimentalApi":true}}"#,
                timeout: 10
            )
            if let error = initialized.error {
                throw LocalizedErrorMessage(error["message"] as? String ?? "Codex app-server initialization failed")
            }
            try write(#"{"jsonrpc":"2.0","method":"initialized","params":null}"#)
        } catch {
            close()
            throw error
        }
    }

    func request(id: Int, method: String, params: String, timeout: TimeInterval) throws -> CodexRPCResponse {
        guard !isClosed, process.isRunning else {
            throw LocalizedErrorMessage("Codex app-server stopped before replying")
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

    private func write(_ line: String) throws {
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    private func readResponse(id: Int, timeout: TimeInterval) throws -> CodexRPCResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while let line = nextLine() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                guard json["id"] as? Int == id else { continue }
                return CodexRPCResponse(result: json["result"], error: json["error"] as? [String: Any])
            }

            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = max(1, min(Int((deadline.timeIntervalSinceNow * 1_000).rounded()), Int(Int32.max)))
            let ready = Darwin.poll(&descriptor, 1, Int32(milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                throw LocalizedErrorMessage("Codex app-server output could not be read")
            }
            if ready == 0 {
                break
            }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EAGAIN && errno != EINTR {
                throw LocalizedErrorMessage("Codex app-server output could not be read")
            }
        }
        throw LocalizedErrorMessage("Codex app-server timed out before replying")
    }

    private func nextLine() -> String? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = String(data: buffer[..<newline], encoding: .utf8)
        buffer.removeSubrange(...newline)
        return line
    }
}
