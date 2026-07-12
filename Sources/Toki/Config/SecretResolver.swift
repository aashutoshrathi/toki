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
        // Drain both pipes before waiting to avoid a full-buffer deadlock.
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalizedErrorMessage(message.isEmpty ? "Command failed: \(command)" : message)
        }
        return output
    }
}
