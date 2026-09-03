import AppKit
import ApplicationServices
import Foundation

struct AgentSessionUsage: Hashable, Sendable {
    let cost: Double?
    let currencyCode: String
    let tokensInput: Int
    let tokensOutput: Int

    init(cost: Double?, tokensInput: Int, tokensOutput: Int, currencyCode: String = "USD") {
        self.cost = cost
        self.currencyCode = Money(amount: 0, currencyCode: currencyCode).currencyCode
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
    }

    var displayCost: String? {
        cost.map { formatMoney(Money(amount: $0, currencyCode: currencyCode)) }
    }

    var displayTokens: String {
        "\(formatCompact(Double(tokensInput))) in / \(formatCompact(Double(tokensOutput))) out"
    }

    var displayLine: String? {
        guard tokensInput > 0 || tokensOutput > 0 else { return displayCost }
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
    // The resolved session/transcript file, disambiguated by process start time. Passed to Remote
    // Control so it shows each co-located agent's own transcript instead of re-guessing by cwd.
    var sessionPath: String? = nil
    // A short marker (the terminal tty) appended to the title only when another agent would
    // otherwise show the same one - several agents in one project can resolve to the same
    // session, and identical rows can't be told apart. Set by a post-scan pass.
    var disambiguator: String? = nil

    var needsInput: Bool { attention != nil }

    // Primary label: the conversation title, else the project folder, else the provider.
    var title: String {
        guard let disambiguator else { return baseTitle }
        return "\(baseTitle) · \(disambiguator)"
    }

    private var baseTitle: String {
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

    // Immutable-per-process fields cached by PID; `command` guards against PID reuse. A tmux
    // host is the exception - it can change under a stable PID - so `hostViaTmux` marks entries
    // that must be re-resolved each scan rather than reused.
    private struct CacheEntry {
        let command: String
        let directory: String?
        let hostApp: HostApp?
        let hostProcessID: Int32?
        let hostViaTmux: Bool
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
            // Transcripts are assigned across the whole scan, not per agent: telling co-located
            // Claude agents apart needs to know about the siblings sharing their project folder.
            let contexts = roots.map(resolveContext)
            let sessions = AgentSessionResolver.assignClaudeSessions(
                contexts.compactMap { context -> AgentSessionResolver.ClaudeAgentIdentity? in
                    guard isClaudeFamily(context.candidate.provider) else { return nil }
                    return AgentSessionResolver.ClaudeAgentIdentity(
                        id: context.candidate.pid,
                        command: context.candidate.command,
                        cwd: context.directory,
                        startTime: context.startTime
                    )
                }
            )
            let agents = disambiguate(contexts.map { buildAgent($0, session: sessions[$0.candidate.pid]) })
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
        if executable == "cursor-agent" { return .cursor }
        if executable == "agy" { return .antigravity }
        if executable == "fx" { return .fx }
        if executable == "grok" { return .grok }
        if executable == "gemini" || (executable == "node" && entrypoint.map { URL(fileURLWithPath: $0).lastPathComponent } == "gemini") { return .gemini }
        if executable == "sarvam-code" { return .sarvamCode }
        return nil
    }

    // Appends the terminal tty to any title shared by two or more agents, so several sessions
    // in one project folder (which can resolve to the same title) render as distinct rows that
    // each still open their own terminal.
    static func disambiguate(_ agents: [ActiveAgent]) -> [ActiveAgent] {
        let collisions = Dictionary(grouping: agents, by: \.title).filter { $0.value.count > 1 }
        guard !collisions.isEmpty else { return agents }
        return agents.map { agent in
            guard collisions[agent.title] != nil, let tty = agent.terminalTTY else { return agent }
            var marked = agent
            marked.disambiguator = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
            return marked
        }
    }

    // A process's launch time, from `ps etime` ([[dd-]hh:]mm:ss) counted back from now, so a
    // session file's creation time can be matched to the agent that opened it.
    static func startDate(fromETime etime: String) -> Date? {
        var rest = Substring(etime)
        var days = 0
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        let hms: Int
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        case 1: hms = parts[0]
        default: return nil
        }
        return Date().addingTimeInterval(-TimeInterval(days * 86400 + hms))
    }

    // The per-process facts that don't change as the conversation does, resolved once so the
    // session assignment can see every agent's folder before any agent is built.
    private struct ProcessContext {
        let candidate: Candidate
        let directory: String?
        let hostApp: HostApp?
        let hostProcessID: Int32?
        let startTime: Date?
    }

    private static func isClaudeFamily(_ provider: Provider) -> Bool {
        provider == .claudeCode || provider == .claude || provider == .anthropic
    }

    // cwd and host app are cached here; title, usage and activity are read per scan in
    // buildAgent, since those change as the conversation evolves.
    private static func resolveContext(_ c: Candidate) -> ProcessContext {
        let cached = cache[c.pid]
        let reusable = cached?.command == c.command ? cached : nil
        let cwd = reusable?.directory
            ?? AgentSessionResolver.workingDirectory(fromCommand: c.command)
            ?? AgentSessionResolver.workingDirectory(ofPID: c.pid)
        // Resolving walks the process tree with up to eight `ps` calls, so it's cached. Reuse a
        // cached host only when it's a settled one: a resolved, non-tmux host (a stable terminal
        // like iTerm or VS Code), or a ttyless agent that has no host to find (re-walking those
        // every scan is the cost the cache exists to avoid). Re-resolve everything else each
        // scan - a cached-nil host on a tty-bearing agent (a detached tmux pane awaiting a
        // client) and any tmux host (whose client can change under a stable PID).
        let cachedHost = reusable.flatMap { entry -> CacheEntry? in
            if entry.hostApp != nil, !entry.hostViaTmux { return entry }
            if entry.hostApp == nil, c.tty == nil { return entry }
            return nil
        }
        let resolvedHost = cachedHost == nil ? AgentSessionResolver.hostApp(ofPID: c.pid, terminalTTY: c.tty) : nil
        let hostApp = cachedHost?.hostApp ?? resolvedHost?.app
        let hostProcessID = cachedHost?.hostProcessID ?? resolvedHost?.processID
        let hostViaTmux = cachedHost?.hostViaTmux ?? (resolvedHost?.viaTmux ?? false)
        cache[c.pid] = CacheEntry(command: c.command, directory: cwd, hostApp: hostApp, hostProcessID: hostProcessID, hostViaTmux: hostViaTmux)
        return ProcessContext(
            candidate: c,
            directory: cwd,
            hostApp: hostApp,
            hostProcessID: hostProcessID,
            // The launch time is what separates two agents sharing one project folder.
            startTime: startDate(fromETime: c.runtime)
        )
    }

    // `session` is Claude's assigned transcript; every field it backs is read from that one file
    // rather than re-resolved four times, which also keeps them describing the same conversation.
    private static func buildAgent(_ context: ProcessContext, session: AgentSessionResolver.ResolvedSession?) -> ActiveAgent {
        let c = context.candidate
        let cwd = context.directory
        let isClaude = isClaudeFamily(c.provider)
        let now = Date()
        return ActiveAgent(
            id: c.pid,
            provider: c.provider,
            directory: cwd,
            chatTitle: isClaude
                ? session.flatMap(AgentSessionResolver.claudeTitle(of:))
                : AgentSessionResolver.chatTitle(provider: c.provider, command: c.command, cwd: cwd, startTime: context.startTime),
            hostApp: context.hostApp,
            hostProcessID: context.hostProcessID,
            lastActivity: isClaude
                ? session?.modified
                : AgentSessionResolver.lastActivity(provider: c.provider, command: c.command, cwd: cwd, startTime: context.startTime),
            processID: c.pid,
            runtime: c.runtime,
            terminalTTY: c.tty,
            memoryKB: c.memoryKB,
            command: c.command,
            sessionUsage: isClaude
                ? session.flatMap(AgentSessionResolver.claudeUsage(of:))
                : AgentSessionResolver.sessionUsage(provider: c.provider, command: c.command, cwd: cwd, startTime: context.startTime),
            attention: isClaude
                ? session.flatMap { AgentSessionResolver.claudeAttention(of: $0, now: now) }
                : AgentSessionResolver.attention(provider: c.provider, command: c.command, cwd: cwd, startTime: context.startTime),
            sessionPath: isClaude
                ? session?.path
                : AgentSessionResolver.sessionPath(provider: c.provider, command: c.command, cwd: cwd, startTime: context.startTime)
        )
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
        let resolvedHostBundleID = agent.hostApp?.bundleID

        Task.detached(priority: .userInitiated) {
            if let device = resolvedDevice,
               terminalScripts(tty: device, hostBundleID: resolvedHostBundleID).contains(where: runAppleScript) {
                return
            }
            await MainActor.run { activateHostApp(for: agent) }
        }
    }

    nonisolated private static func terminalScripts(tty: String, hostBundleID: String?) -> [String] {
        switch hostBundleID {
        case HostApp.iTerm.bundleID:
            [iTermScript(tty: tty)]
        case HostApp.ghostty.bundleID:
            [ghosttyScript(tty: tty)]
        case HostApp.terminal.bundleID:
            [terminalScript(tty: tty)]
        default:
            [iTermScript(tty: tty), ghosttyScript(tty: tty), terminalScript(tty: tty)]
        }
    }

    private static func activateHostApp(for agent: ActiveAgent) {
        // By PID first: two builds of a terminal share a bundle identifier, so an
        // identifier lookup can raise the copy that does not hold this agent. Only when
        // that PID is a regular activatable app, though: VS Code's integrated terminal runs
        // under a "Code Helper" process whose activation policy is .prohibited, so activating
        // it silently does nothing - the click has to fall through to the real app below.
        if let hostProcessID = agent.hostProcessID,
           let running = NSRunningApplication(processIdentifier: pid_t(hostProcessID)),
           running.activationPolicy == .regular {
            running.activate(options: [.activateAllWindows])
            raiseWorkspaceWindow(pid: running.processIdentifier, bundleID: running.bundleIdentifier, directory: agent.directory)
            return
        }

        // Fall back to identity: for a helper-hosted app (VS Code) this raises the real app.
        // The host's own bundle id is matched first and exactly, so with both VS Code and VS
        // Code Insiders running the click lands on the variant that actually holds the agent
        // rather than whichever the system happens to list first.
        if let host = agent.hostApp, activate(bundleID: host.bundleID, directory: agent.directory) {
            return
        }
        // Only when the ancestry walk named no host: raise any known terminal that's running.
        for bundleID in [HostApp.iTerm.bundleID, HostApp.terminal.bundleID, "com.microsoft.VSCode"]
        where activate(bundleID: bundleID, directory: agent.directory) {
            return
        }
        DiagnosticLogger.shared.record(.warning, component: "agents", code: "navigation_unavailable")
    }

    @discardableResult
    private static func activate(bundleID: String, directory: String?) -> Bool {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
        }) else { return false }
        application.activate(options: [.activateAllWindows])
        raiseWorkspaceWindow(pid: application.processIdentifier, bundleID: bundleID, directory: directory)
        return true
    }

    private static let workspaceWindowBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium",
    ]

    private static var didPromptAccessibility = false

    private static func hasAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !didPromptAccessibility {
            didPromptAccessibility = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return false
    }

    private static func raiseWorkspaceWindow(pid: pid_t, bundleID: String?, directory: String?) {
        guard let bundleID, workspaceWindowBundleIDs.contains(bundleID), let directory,
              !WorkspaceWindowMatcher.nameCandidates(for: directory).isEmpty,
              hasAccessibilityAccess() else { return }

        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }

        let infos = windows.map {
            WorkspaceWindowMatcher.WindowInfo(title: windowTitle($0) ?? "", documentPath: windowDocumentPath($0))
        }
        guard let index = WorkspaceWindowMatcher.pick(directory: directory, windows: infos) else { return }
        let target = windows[index]
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func windowDocumentPath(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success,
              let document = value as? String else { return nil }
        return WorkspaceWindowMatcher.documentPath(fromRawValue: document)
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
        if application id "\(HostApp.iTerm.bundleID)" is running then
          tell application id "\(HostApp.iTerm.bundleID)"
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

    nonisolated private static func ghosttyScript(tty: String) -> String {
        """
        if application id "\(HostApp.ghostty.bundleID)" is running then
          tell application id "\(HostApp.ghostty.bundleID)"
            repeat with t in terminals
              if tty of t is "\(tty)" then
                focus t
                return
              end if
            end repeat
          end tell
        end if
        error "TTY not found"
        """
    }

    nonisolated private static func terminalScript(tty: String) -> String {
        """
        if application id "\(HostApp.terminal.bundleID)" is running then
          tell application id "\(HostApp.terminal.bundleID)"
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

enum WorkspaceWindowMatcher {
    struct WindowInfo: Equatable {
        let title: String
        let documentPath: String?
    }

    static func pick(directory: String, windows: [WindowInfo]) -> Int? {
        let candidates = nameCandidates(for: directory)
        guard !candidates.isEmpty else { return nil }

        for candidate in candidates {
            guard let rootPath = root(of: directory, named: candidate).map(resolved) else { continue }
            if let index = windows.firstIndex(where: { window in
                titleMatches(window.title, name: candidate)
                    && (window.documentPath.map { isPath(resolved($0), under: rootPath) } ?? false)
            }) {
                return index
            }
        }
        for candidate in candidates {
            guard let rootPath = root(of: directory, named: candidate).map(resolved) else { continue }
            let matches = windows.indices.filter { index in
                let window = windows[index]
                guard titleMatches(window.title, name: candidate) else { return false }
                if let document = window.documentPath,
                   let otherRoot = root(of: document, named: candidate).map(resolved),
                   otherRoot != rootPath {
                    return false
                }
                return true
            }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    static func resolved(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    static func documentPath(fromRawValue raw: String) -> String? {
        if let url = URL(string: raw), url.isFileURL { return url.path }
        if raw.hasPrefix("/") { return raw }
        return nil
    }

    static func titleMatches(_ title: String, name: String) -> Bool {
        title == name || title.hasSuffix(" \(name)")
    }

    static func isPath(_ path: String, under root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func nameCandidates(for directory: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var names: [String] = []
        var path = (directory as NSString).standardizingPath
        while !path.isEmpty, path != "/", path != home {
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty, name != "/" { names.append(name) }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        return names
    }

    static func root(of directory: String, named candidate: String) -> String? {
        var path = (directory as NSString).standardizingPath
        while !path.isEmpty, path != "/" {
            if (path as NSString).lastPathComponent == candidate { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        return nil
    }
}
