import AppKit
import Foundation

struct ActiveAgent: Identifiable, Hashable, Sendable {
    let id: Int32
    let provider: Provider
    let title: String
    let chatTitle: String?
    let hostApp: String?
    let processID: Int32
    let runtime: String
    let terminalTTY: String?

    // Every agent can be surfaced: TTY-backed ones focus the exact terminal tab,
    // the rest fall back to activating the likely host app.
    var canNavigate: Bool { true }

    // Whether navigation lands on an exact terminal tab (vs. a best-effort host-app focus).
    var hasTerminalTarget: Bool { terminalTTY != nil }
}

enum ActiveAgentScanner {
    private struct Candidate {
        let agent: ActiveAgent
        let parentPID: Int32
    }

    static func scan() async -> [ActiveAgent] {
        await Task.detached(priority: .utility) {
            do {
                let output = try processOutput(
                    executable: "/bin/ps",
                    arguments: ["-axo", "pid=,ppid=,tty=,etime=,command="]
                )
                let candidates = output.split(separator: "\n").compactMap(parse(line:))
                let roots = candidates.filter { candidate in
                    !candidates.contains { possibleParent in
                        possibleParent.agent.processID == candidate.parentPID
                            && possibleParent.agent.provider == candidate.agent.provider
                    }
                }.map(\.agent)
                return roots.sorted { lhs, rhs in
                    if lhs.provider.displayName == rhs.provider.displayName {
                        return lhs.processID < rhs.processID
                    }
                    return lhs.provider.displayName < rhs.provider.displayName
                }
            } catch {
                DiagnosticLogger.shared.record(.warning, component: "agents", code: "scan_failed", detail: diagnosticErrorDetail(error))
                return []
            }
        }.value
    }

    private static func parse(line: Substring) -> Candidate? {
        let parts = line.split(maxSplits: 4, whereSeparator: { $0.isWhitespace })
        guard parts.count == 5, let pid = Int32(parts[0]), let parentPID = Int32(parts[1]) else { return nil }
        let ttyValue = String(parts[2])
        let runtime = String(parts[3])
        let command = String(parts[4])
        let commandParts = command.split(whereSeparator: { $0.isWhitespace })
        guard let executablePath = commandParts.first else { return nil }
        let executable = URL(fileURLWithPath: String(executablePath)).lastPathComponent.lowercased()
        let entrypoint = commandParts.dropFirst().first.map { String($0).lowercased() }
        let normalizedCommand = command.lowercased()
        guard !normalizedCommand.contains("app-server"), !normalizedCommand.contains(".app/contents/") else { return nil }

        let provider: Provider
        if executable == "opencode" {
            provider = .openCode
        } else if executable == "copilot"
                    || (executable == "node" && entrypoint?.contains("/@github/copilot/") == true) {
            provider = .copilot
        } else if executable == "codex"
                    || executable.hasPrefix("codex-")
                    || (executable == "node" && entrypoint?.contains("/@openai/codex/") == true) {
            provider = .codex
        } else if executable == "claude" {
            provider = .claudeCode
        } else {
            return nil
        }

        let tty = ttyValue == "??" || ttyValue == "-" ? nil : ttyValue
        let cwd = AgentSessionResolver.workingDirectory(fromCommand: command)
            ?? AgentSessionResolver.workingDirectory(ofPID: pid)
        let title = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "\(provider.displayName) agent"
        return Candidate(
            agent: ActiveAgent(
                id: pid,
                provider: provider,
                title: title,
                chatTitle: AgentSessionResolver.chatTitle(provider: provider, command: command, cwd: cwd),
                hostApp: AgentSessionResolver.hostApp(ofPID: pid),
                processID: pid,
                runtime: runtime,
                terminalTTY: tty
            ),
            parentPID: parentPID
        )
    }

    private static func processOutput(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain the pipe before waiting: ps output exceeds the ~64KB pipe buffer,
        // so waiting first would deadlock ps against a full, unread pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalizedErrorMessage("Process inspection failed")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@MainActor
enum ActiveAgentNavigator {
    static func navigate(to agent: ActiveAgent) {
        if let tty = agent.terminalTTY, isSafeTTY(tty) {
            let device = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            if runAppleScript(iTermScript(tty: device)) || runAppleScript(terminalScript(tty: device)) {
                return
            }
        }

        let bundleIDs = ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode"]
        if let application = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleIdentifier.map(bundleIDs.contains) == true
        }) {
            application.activate(options: [.activateAllWindows])
        } else {
            DiagnosticLogger.shared.record(.warning, component: "agents", code: "navigation_unavailable")
        }
    }

    private static func isSafeTTY(_ value: String) -> Bool {
        value.range(of: #"^(/dev/)?[a-zA-Z0-9]+$"#, options: .regularExpression) != nil
    }

    private static func runAppleScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func iTermScript(tty: String) -> String {
        """
        if application "iTerm2" is running then
          tell application "iTerm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is "\(tty)" then
                    select t
                    select s
                    activate
                    return
                  end if
                end repeat
              end repeat
            end repeat
          end tell
        end if
        error "TTY not found"
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        if application "Terminal" is running then
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is "\(tty)" then
                  set selected of t to true
                  set index of w to 1
                  activate
                  return
                end if
              end repeat
            end repeat
          end tell
        end if
        error "TTY not found"
        """
    }
}
