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

// An agent that has stopped and is waiting on the user - either because it asked a question
// outright, or because a tool call is sitting on a permission prompt.
struct AgentAttention: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case question
        case permission
    }

    let kind: Kind
    // The question text when the agent asked one, or the tool awaiting approval. Shown
    // truncated on the card so the user can tell what's blocked without switching to it.
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
    /// PID of the GUI app hosting this agent. Needed to focus the right one when two builds of
    /// the same terminal run at once and therefore share a bundle identifier.
    let hostProcessID: Int32?
    let lastActivity: Date?
    let processID: Int32
    let runtime: String
    let terminalTTY: String?
    // Resident set size in kilobytes, straight from `ps rss=` - the same figure Activity
    // Monitor's "Memory" column shows.
    let memoryKB: Int
    // The full command line at scan time - kept only so ActiveAgentTerminator can confirm
    // the PID still refers to this same process immediately before signalling it.
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
        let pid: Int32
        let parentPID: Int32
        let provider: Provider
        let command: String
        let runtime: String
        let tty: String?
        let memoryKB: Int
    }

    // Caches the immutable-per-process fields (cwd, host app) by PID so they're resolved
    // once, not on every scan tick. `command` guards against PID reuse. Accessed only from
    // the serialized scan task (UsageStore gates concurrent scans).
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
            // Most recently active session first; agents without a known
            // activity time fall to the bottom, tie-broken by provider and PID.
            return agents.sorted { lhs, rhs in
                // Deliberately NOT sorted by whether the agent needs input.
                //
                // Promoting blocked agents to the top re-orders the list whenever one changes
                // state, which happens while the user is looking at it. A row moving out from
                // under the pointer mid-press cancels the click, so the cards silently stopped
                // being clickable. Attention is surfaced by the dot, the row's own text, and
                // the tab and menu bar badges - none of which move anything.
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

    // Cheap, I/O-free parse: identify the provider, tty, and lineage from the ps row.
    // Enrichment (cwd, host, title, activity) happens later, only for root agents.
    private static func parse(line: Substring) -> Candidate? {
        let parts = line.split(maxSplits: 5, whereSeparator: { $0.isWhitespace })
        guard parts.count == 6, let pid = Int32(parts[0]), let parentPID = Int32(parts[1]) else { return nil }
        let memoryKB = Int(parts[4]) ?? 0
        let command = String(parts[5])
        let commandParts = command.split(whereSeparator: { $0.isWhitespace })
        guard let executablePath = commandParts.first else { return nil }
        let executable = URL(fileURLWithPath: String(executablePath)).lastPathComponent.lowercased()
        let entrypoint = commandParts.dropFirst().first.map { String($0).lowercased() }

        // Classify by executable first. A recognized agent binary is a real agent no matter
        // where it lives (e.g. Codex inside ChatGPT.app); the bundle-helper noise filter
        // only decides whether an UNRECOGNIZED process is worth ignoring.
        guard let provider = providerForProcess(executable: executable, entrypoint: entrypoint) else {
            return nil
        }

        // Reject GUI-app helper processes (renderers, GPU, framework helpers) that live
        // inside an .app bundle. The genuine in-bundle agent identifies itself with
        // "app-server" (e.g. ChatGPT.app's Codex); everything else under Contents/ is noise.
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

    // Resolves the expensive fields. cwd and host app are truly immutable for a live
    // process, so they're cached by PID (validated against the command line to survive
    // PID reuse). chatTitle and lastActivity change as the session evolves, so they're
    // re-resolved every scan.
    private static func enrich(_ c: Candidate) -> ActiveAgent {
        let cached = cache[c.pid]
        let reusable = cached?.command == c.command ? cached : nil
        let cwd = reusable?.directory
            ?? AgentSessionResolver.workingDirectory(fromCommand: c.command)
            ?? AgentSessionResolver.workingDirectory(ofPID: c.pid)
        let resolvedHost = AgentSessionResolver.hostApp(ofPID: c.pid)
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
    // SIGTERM, not SIGKILL - gives the agent a chance to exit the way Ctrl-C in its own
    // terminal would, instead of yanking it out from under any in-progress file write.
    //
    // Re-checks that the PID still belongs to the same process immediately before
    // signalling it. The confirmation dialog can sit open for a while (and even without
    // it, the scan that produced this agent may already be stale), and macOS reuses PIDs -
    // without this, an agent that already exited could have its PID reassigned to some
    // unrelated process by the time "Quit" is actually clicked, which would then be the
    // one to receive the signal instead.
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
    // The AppleScript runs off the main actor, and never blocks the UI.
    //
    // osascript was previously waited on synchronously here. Anything that makes it hang -
    // an app-chooser dialog, a terminal busy servicing another Apple event, a build that
    // stops responding - froze the whole app, which reads as "clicking the card does nothing"
    // rather than as a hang. Scripting is inherently other-process work with no bounded
    // response time, so it does not belong on the main actor.
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
        // The agent's own host process, by PID, before anything identifier-based.
        //
        // Two builds of the same terminal report the same bundle identifier, so picking the
        // first running app with a matching identifier can raise the copy that does not
        // contain this agent - which looks like the click doing nothing. Walking the agent's
        // process ancestry already told us exactly which process owns it.
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

        // A hard ceiling on how long a scripted app gets to answer. Focusing a terminal tab is
        // near-instant when it works; anything still running after this is stuck on something
        // the user cannot see - a modal chooser, an app not servicing Apple events - and would
        // otherwise leave the process resident indefinitely.
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

    // Addressed by bundle id, not by name.
    //
    // `tell application "iTerm2"` resolves through LaunchServices by name, which is ambiguous
    // as soon as more than one iTerm-family bundle is installed - iTermAI ships as a separate
    // app whose identifier shares the same prefix. A name that resolves to more than one
    // candidate can target the wrong build, or make AppleScript put up a "Where is...?" chooser
    // that blocks osascript until it is dismissed. A bundle id has exactly one answer.
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
