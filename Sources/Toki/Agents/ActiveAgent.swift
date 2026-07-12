import AppKit
import Foundation

struct ActiveAgent: Identifiable, Hashable, Sendable {
    let id: Int32
    let provider: Provider
    let directory: String?
    let chatTitle: String?
    let hostApp: String?
    let lastActivity: Date?
    let processID: Int32
    let runtime: String
    let terminalTTY: String?

    // Primary label: the conversation title, else the project folder, else the provider.
    var title: String {
        if let chatTitle { return chatTitle }
        if let folder = directory.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty, folder != "/" {
            return folder
        }
        return "\(provider.displayName) agent"
    }

    // Working directory shown relative to home (~/Code/tokenbar), when meaningful.
    // Root or app-bundle cwds (e.g. GUI-hosted agents) carry no useful project, so
    // they're hidden rather than shown as a bare "/".
    var directoryDisplay: String? {
        guard let directory, directory != "/", !directory.contains("/.app/"), !directory.hasSuffix(".app") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

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
                // Most recently active session first; agents without a known
                // activity time fall to the bottom, tie-broken by provider and PID.
                return roots.sorted { lhs, rhs in
                    let l = lhs.lastActivity ?? .distantPast
                    let r = rhs.lastActivity ?? .distantPast
                    if l != r { return l > r }
                    if lhs.provider.displayName != rhs.provider.displayName {
                        return lhs.provider.displayName < rhs.provider.displayName
                    }
                    return lhs.processID < rhs.processID
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
        // The ChatGPT desktop app hosts a real Codex agent at
        // .../Contents/Resources/codex ... app-server - allow it through the noise
        // filters below, which otherwise reject everything under an .app bundle.
        let isChatGPTCodex = executable == "codex"
            && normalizedCommand.contains("chatgpt.app/contents/resources/codex")
            && normalizedCommand.contains("app-server")
        if !isChatGPTCodex {
            guard !normalizedCommand.contains("app-server"), !normalizedCommand.contains(".app/contents/") else { return nil }
        }

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
        return Candidate(
            agent: ActiveAgent(
                id: pid,
                provider: provider,
                directory: cwd,
                chatTitle: AgentSessionResolver.chatTitle(provider: provider, command: command, cwd: cwd),
                hostApp: AgentSessionResolver.hostApp(ofPID: pid),
                lastActivity: AgentSessionResolver.lastActivity(provider: provider, command: command, cwd: cwd),
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

        // Prefer the agent's actual resolved host app; fall back to common host apps.
        var bundleIDs: [String] = []
        if let host = agent.hostApp, let id = AgentSessionResolver.bundleID(forHostApp: host) {
            bundleIDs.append(id)
        }
        bundleIDs.append(contentsOf: ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode"])
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
