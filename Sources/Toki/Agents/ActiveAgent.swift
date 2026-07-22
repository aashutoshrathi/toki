import AppKit
import Foundation

struct AgentSessionUsage: Hashable, Sendable {
    let cost: Double?
    let tokensInput: Int
    let tokensOutput: Int

    var displayCost: String? {
        cost.map { formatUSD($0) }
    }

    var displayTokens: String {
        "\(formatCompact(Double(tokensInput))) in / \(formatCompact(Double(tokensOutput))) out"
    }

    var displayLine: String? {
        guard tokensInput > 0 || tokensOutput > 0 else { return cost.map { formatUSD($0) } }
        if let costStr = displayCost {
            return "\(costStr) • \(displayTokens)"
        }
        return displayTokens
    }
}

// An agent stopped waiting on the user: a question, or a pending permission prompt.
struct AgentAttention: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case question
        case permission
    }

    let kind: Kind

    let prompt: String?

    var summary: String {
        if let prompt, !prompt.isEmpty { return prompt }
        return kind == .question ? "Waiting on your answer" : "Waiting for permission"
    }
}

struct ActiveAgent: Identifiable, Hashable, Sendable {
    let id: Int32
    let provider: Provider
    let directory: String?
    let chatTitle: String?
    let hostApp: HostApp?
    /// Needed to focus the right copy when two builds share a bundle identifier.
    let hostProcessID: Int32?
    let lastActivity: Date?
    let processID: Int32
    let runtime: String
    let terminalTTY: String?
    // Resident set size in kB from `ps rss=`.
    let memoryKB: Int
    // Kept so termination can confirm the PID still refers to this process.
    let command: String
    // Per-session cost and token usage, resolved from local session data when available.
    let sessionUsage: AgentSessionUsage?
    // Set when the session is parked waiting on the user (a question or a permission prompt).
    let attention: AgentAttention?

    var needsInput: Bool { attention != nil }

    // Primary label: the conversation title, else the project folder, else the provider.
    var title: String {
        if let chatTitle { return chatTitle }
        if let folder = directory.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty, folder != "/" {
            return folder
        }
        return "\(provider.displayName) agent"
    }

    var memoryDisplay: String {
        let mb = Double(memoryKB) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    // Relative to home when meaningful; root and app-bundle cwds carry no useful project.
    var directoryDisplay: String? {
        guard let directory, directory != "/", !directory.contains("/.app/"), !directory.hasSuffix(".app") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    // Whether navigation lands on an exact terminal tab (vs. a best-effort host-app focus).
    var hasTerminalTarget: Bool { terminalTTY != nil }
}

enum ActiveAgentScanner {
    private struct Candidate {
        let pid: Int32
        let parentPID: Int32
        let provider: Provider
        let command: String
        let runtime: String
        let tty: String?
        let memoryKB: Int
    }

    // Immutable-per-process fields cached by PID; `command` guards against PID reuse.
    private struct CacheEntry {
        let command: String
        let directory: String?
        let hostApp: HostApp?
        let hostProcessID: Int32?
    }
    private nonisolated(unsafe) static var cache: [Int32: CacheEntry] = [:]

    static func scan() async -> [ActiveAgent] {
        await Task.detached(priority: .utility) {
            guard let output = Shell.output("/bin/ps", ["-axo", "pid=,ppid=,tty=,etime=,rss=,command="]) else {
                DiagnosticLogger.shared.record(.warning, component: "agents", code: "scan_failed")
                return []
            }
            let candidates = output.split(separator: "\n").compactMap(parse(line:))
            let roots = candidates.filter { candidate in
                !candidates.contains { possibleParent in
                    possibleParent.pid == candidate.parentPID && possibleParent.provider == candidate.provider
                }
            }
            let agents = roots.map(enrich)
            // Drop cache entries for PIDs that are no longer running.
            let alive = Set(candidates.map(\.pid))
            cache = cache.filter { alive.contains($0.key) }

            return agents.sorted { lhs, rhs in
                // Deliberately not sorted by needsInput: a row that moves while the pointer is
                // over it cancels the click. Attention is shown by the dot and badges instead.
                let l = lhs.lastActivity ?? .distantPast
                let r = rhs.lastActivity ?? .distantPast
                if l != r { return l > r }
                if lhs.provider.displayName != rhs.provider.displayName {
                    return lhs.provider.displayName < rhs.provider.displayName
                }
                return lhs.processID < rhs.processID
            }
        }.value
    }

    // I/O-free; enrichment happens later and only for root agents.
    private static func parse(line: Substring) -> Candidate? {
        let parts = line.split(maxSplits: 5, whereSeparator: { $0.isWhitespace })
        guard parts.count == 6, let pid = Int32(parts[0]), let parentPID = Int32(parts[1]) else { return nil }
        let memoryKB = Int(parts[4]) ?? 0
        let command = String(parts[5])
        let commandParts = command.split(whereSeparator: { $0.isWhitespace })
        guard let executablePath = commandParts.first else { return nil }
        let executable = URL(fileURLWithPath: String(executablePath)).lastPathComponent.lowercased()
        let entrypoint = commandParts.dropFirst().first.map { String($0).lowercased() }

        // Classify by executable first.
        guard let provider = providerForProcess(executable: executable, entrypoint: entrypoint) else {
            return nil
        }

        // Reject GUI-app helper processes; a genuine in-bundle agent says "app-server".
        let normalized = command.lowercased()
        if normalized.contains(".app/contents/"), !normalized.contains("app-server") {
            return nil
        }

        let ttyValue = String(parts[2])
        let tty = ttyValue == "??" || ttyValue == "-" ? nil : ttyValue
        return Candidate(pid: pid, parentPID: parentPID, provider: provider, command: command, runtime: String(parts[3]), tty: tty, memoryKB: memoryKB)
    }

    static func providerForCommand(_ command: String) -> Provider? {
        let parts = command.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return nil }
        let executable = URL(fileURLWithPath: String(first)).lastPathComponent.lowercased()
        return providerForProcess(executable: executable, entrypoint: parts.dropFirst().first.map { String($0).lowercased() })
    }

    private static func providerForProcess(executable: String, entrypoint: String?) -> Provider? {
        if executable == "pi" { return .pi }
        if (executable == "node" || executable == "bun"), let entrypoint,
           entrypoint.contains("/@earendil-works/pi-coding-agent/")
            || entrypoint.contains("/@mariozechner/pi-coding-agent/") {
            return .pi
        }
        if executable == "opencode" { return .openCode }
        if executable == "copilot" || (executable == "node" && entrypoint?.contains("/@github/copilot/") == true) { return .copilot }
        if executable == "codex" || executable.hasPrefix("codex-") || (executable == "node" && entrypoint?.contains("/@openai/codex/") == true) { return .codex }
        if executable == "claude" { return .claudeCode }
        if executable == "grok" { return .grok }
        if executable == "gemini" || (executable == "node" && entrypoint.map { URL(fileURLWithPath: $0).lastPathComponent } == "gemini") { return .gemini }
        return nil
    }

    // cwd and host app are cached; title and activity change as the session evolves.
    private static func enrich(_ c: Candidate) -> ActiveAgent {
        let cached = cache[c.pid]
        let reusable = cached?.command == c.command ? cached : nil
        let cwd = reusable?.directory
            ?? AgentSessionResolver.workingDirectory(fromCommand: c.command)
            ?? AgentSessionResolver.workingDirectory(ofPID: c.pid)
        // Only when the cache can't answer: this walks the process tree with up to eight
        // `ps` calls per agent.
        let resolvedHost = reusable == nil ? AgentSessionResolver.hostApp(ofPID: c.pid) : nil
        let hostApp = reusable?.hostApp ?? resolvedHost?.app
        let hostProcessID = reusable?.hostProcessID ?? resolvedHost?.processID
        let chatTitle = AgentSessionResolver.chatTitle(provider: c.provider, command: c.command, cwd: cwd)
        let agent = ActiveAgent(
            id: c.pid,
            provider: c.provider,
            directory: cwd,
            chatTitle: chatTitle,
            hostApp: hostApp,
            hostProcessID: hostProcessID,
            lastActivity: AgentSessionResolver.lastActivity(provider: c.provider, command: c.command, cwd: cwd),
            processID: c.pid,
            runtime: c.runtime,
            terminalTTY: c.tty,
            memoryKB: c.memoryKB,
            command: c.command,
            sessionUsage: AgentSessionResolver.sessionUsage(provider: c.provider, command: c.command, cwd: cwd),
            attention: AgentSessionResolver.attention(provider: c.provider, command: c.command, cwd: cwd)
        )
        cache[c.pid] = CacheEntry(command: c.command, directory: cwd, hostApp: hostApp, hostProcessID: hostProcessID)
        return agent
    }
}

@MainActor
enum ActiveAgentTerminator {
    // SIGTERM, not SIGKILL, so the agent can exit cleanly. The PID is re-checked first:
    // macOS reuses PIDs and the confirmation dialog can sit open for a while.
    static func terminate(_ agent: ActiveAgent) {
        let currentCommand = Shell.output("/bin/ps", ["-p", String(agent.processID), "-o", "command="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentCommand == agent.command else {
            DiagnosticLogger.shared.record(.warning, component: "agents", code: "terminate_stale_pid")
            return
        }
        kill(agent.processID, SIGTERM)
    }
}

@MainActor
enum ActiveAgentNavigator {
    // Off the main actor: osascript can hang on an app-chooser dialog or an unresponsive
    // terminal, and waiting on it synchronously froze the app.
    static func navigate(to agent: ActiveAgent) {
        var device: String?
        if let tty = agent.terminalTTY, isSafeTTY(tty) {
            device = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        }
        let resolvedDevice = device

        Task.detached(priority: .userInitiated) {
            if let device = resolvedDevice,
               runAppleScript(iTermScript(tty: device)) || runAppleScript(terminalScript(tty: device)) {
                return
            }
            await MainActor.run { activateHostApp(for: agent) }
        }
    }

    private static func activateHostApp(for agent: ActiveAgent) {
        // By PID first: two builds of a terminal share a bundle identifier, so an
        // identifier lookup can raise the copy that does not hold this agent.
        if let hostProcessID = agent.hostProcessID,
           let running = NSRunningApplication(processIdentifier: pid_t(hostProcessID)) {
            running.activate(options: [.activateAllWindows])
            return
        }

        // Fall back to identity when the ancestry walk found nothing.
        var bundleIDs: [String] = []
        if let host = agent.hostApp {
            bundleIDs.append(host.bundleID)
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

    nonisolated private static func isSafeTTY(_ value: String) -> Bool {
        value.range(of: #"^(/dev/)?[a-zA-Z0-9]+$"#, options: .regularExpression) != nil
    }

    nonisolated private static func runAppleScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }

        // Ceiling: focusing a tab is near-instant, so anything still running is stuck.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            DiagnosticLogger.shared.record(.warning, component: "agents", code: "applescript_timeout")
            return false
        }
        return process.terminationStatus == 0
    }

    // By bundle id, not name: `tell application "iTerm2"` is ambiguous once iTermAI is also
    // installed, and can raise a blocking "Where is...?" chooser.
    nonisolated private static func iTermScript(tty: String) -> String {
        """
        if application id "com.googlecode.iterm2" is running then
          tell application id "com.googlecode.iterm2"
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

    nonisolated private static func terminalScript(tty: String) -> String {
        """
        if application id "com.apple.Terminal" is running then
          tell application id "com.apple.Terminal"
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
