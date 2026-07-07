import Foundation

enum ClaudeSwapRunner {
    static func switchTo(target: String, command configuredCommand: String?) throws {
        let path = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let executable = configuredCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "claude-swap"
        let command = "PATH=\"\(path)\" '\(shellEscaped(executable))' --switch-to '\(shellEscaped(target))'"
        _ = try SecretResolver.runShell(command)
    }
}
