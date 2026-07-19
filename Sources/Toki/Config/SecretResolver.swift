import Foundation

enum SecretResolver {
    static func resolve(account: AccountConfig) throws -> String {
        if let apiKey = account.apiKey, !apiKey.isEmpty {
            return apiKey
        }
        if let envName = account.apiKeyEnv, let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
            return value
        }
        if let command = account.apiKeyCommand, !command.isEmpty {
            let value = try runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        throw LocalizedErrorMessage("No API key configured for \(account.name)")
    }

    static func runShell(_ command: String) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        // Read pipes concurrently to avoid deadlock if child writes more than pipe buffer (64KB).
        let group = DispatchGroup()
        var outputData = Data()
        var errorData = Data()
        group.enter()
        DispatchQueue.global().async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        // Timeout after 15 seconds to prevent hung processes from blocking Toki.
        let deadline = DispatchTime.now() + 15
        let processGroup = DispatchGroup()
        processGroup.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            processGroup.leave()
        }
        let exited = processGroup.wait(timeout: deadline) == .success
        if !exited {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw LocalizedErrorMessage("API key command timed out")
        }
        _ = group.wait(timeout: .now() + 2)
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalizedErrorMessage(message.isEmpty ? "API key command failed" : message)
        }
        return output
    }
}
