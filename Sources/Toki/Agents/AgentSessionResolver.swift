import Foundation

// Per-provider resolution of title, usage, attention and last activity from local session
// stores.
enum AgentSessionResolver {
    // The human/AI-assigned conversation title, if the provider records one.
    static func chatTitle(provider: Provider, command: String, cwd: String?) -> String? {
        switch provider {
        case .claudeCode, .claude, .anthropic:
            return claudeChatTitle(command: command, cwd: cwd)
        case .openCode:
            return openCodeChatTitle(cwd: cwd)
        case .grok:
            return newestGrokSession(cwd: cwd)?.title
        case .pi:
            return PiUsageClient.latestSession(cwd: cwd)?.title
        default:
            return nil
        }
    }

    // Per-session cost and token usage, resolved from local session data when available.
    static func sessionUsage(provider: Provider, command: String, cwd: String?) -> AgentSessionUsage? {
        switch provider {
        case .openCode:
            return openCodeSessionUsage(cwd: cwd)
        case .pi:
            return piSessionUsage(cwd: cwd)
        case .claudeCode, .claude, .anthropic:
            return claudeSessionUsage(command: command, cwd: cwd)
        default:
            return nil
        }
    }

    // Whether the session is parked waiting on the user, and what it's waiting for.
    static func attention(provider: Provider, command: String, cwd: String?) -> AgentAttention? {
        switch provider {
        case .claudeCode, .claude, .anthropic:
            guard let session = newestClaudeSession(command: command, cwd: cwd),
                  let parsed = claudeSession(at: session.path, modified: session.modified) else { return nil }
            return attention(from: parsed, modified: session.modified, now: Date())
        case .openCode:
            return openCodeAttention(cwd: cwd, now: Date())
        default:
            return nil
        }
    }

    struct ParsedClaudeSession: Sendable {
        var usage: AgentSessionUsage?
        /// Whether this counts as "blocked" depends on elapsed time, so that is left to the
        /// caller - baking it in here would expire the cache every second.
        var pendingTool: (name: String, question: String?)?
        /// The session's current permission mode ("auto", "acceptEdits", "plan", "default"),
        /// last value wins. In auto mode tools run without a prompt, so a pending tool_use is
        /// executing rather than waiting - the caller uses this to avoid a false permission
        /// attention.
        var permissionMode: String?
    }

    // Session files reach tens of megabytes and both usage and attention need the same parse.
    // Cached on path, mtime and size, so an unchanged file is never re-read.
    private struct ClaudeCacheEntry {
        let modified: Date?
        let size: Int
        let parsed: ParsedClaudeSession
    }
    private nonisolated(unsafe) static var claudeCache: [String: ClaudeCacheEntry] = [:]

    static func claudeSession(at path: String, modified: Date?) -> ParsedClaudeSession? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
        if let cached = claudeCache[path], cached.modified == modified, cached.size == size {
            return cached.parsed
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let parsed = parseClaudeSession(data: data)
        claudeCache[path] = ClaudeCacheEntry(modified: modified, size: size, parsed: parsed)
        // Drop entries whose session file no longer exists.
        if claudeCache.count > 64 {
            claudeCache = claudeCache.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
        return parsed
    }

    // A `part` row left in state.status "running" is OpenCode's equivalent of an unresolved
    // tool_use. The `permission` table is a persisted allow-list, not a queue of prompts.
    private static func openCodeAttention(cwd: String?, now: Date) -> AgentAttention? {
        guard let cwd, let safe = safeSQLPath(cwd) else { return nil }
        let query = """
        SELECT json_extract(data,'$.tool'), time_updated FROM part \
        WHERE session_id = (SELECT id FROM session WHERE directory='\(safe)' ORDER BY time_updated DESC LIMIT 1) \
        AND json_extract(data,'$.state.status') = 'running' \
        ORDER BY time_updated DESC LIMIT 1;
        """
        guard let raw = OpenCodeUsageClient.queryValue(query), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let milliseconds = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }

        // Same quiet-period reasoning as Claude: a tool that is genuinely executing updates
        // its row promptly, so only a stale `running` row means "stopped, waiting on you".
        let updated = Date(timeIntervalSince1970: milliseconds / 1000)
        guard now.timeIntervalSince(updated) >= attentionQuietPeriod else { return nil }

        let tool = parts[0].trimmingCharacters(in: .whitespaces)
        return AgentAttention(kind: .permission, prompt: tool.isEmpty ? nil : "Allow \(tool)?")
    }

    // A running tool writes its result within moments; a prompt sits indefinitely. Quiet time
    // is what separates them.
    private static let attentionQuietPeriod: TimeInterval = 10

    // A tool_use with no matching tool_result means the session stopped and is waiting.
    // `now` and `modified` are injected so the quiet-period gate is testable.
    static func claudeAttention(fromJSONLData data: Data, modified: Date?, now: Date) -> AgentAttention? {
        attention(from: parseClaudeSession(data: data), modified: modified, now: now)
    }

    static func attention(from parsed: ParsedClaudeSession, modified: Date?, now: Date) -> AgentAttention? {
        // A file still being written to is an agent that's working, not one that's waiting.
        guard let modified, now.timeIntervalSince(modified) >= attentionQuietPeriod else { return nil }
        guard let pending = parsed.pendingTool else { return nil }

        switch pending.name {
        case "AskUserQuestion":
            return AgentAttention(kind: .question, prompt: pending.question)
        case "ExitPlanMode", "EnterPlanMode":
            return AgentAttention(kind: .question, prompt: "Waiting on plan approval")
        default:
            // Auto mode runs every tool without a prompt, and acceptEdits does the same for
            // file edits, so a lingering tool_use there is a command still executing - not one
            // waiting on you. Only a mode that would actually prompt yields a permission alert.
            if parsed.permissionMode == "auto" { return nil }
            if parsed.permissionMode == "acceptEdits", isAutoAcceptedEdit(pending.name) { return nil }
            return AgentAttention(kind: .permission, prompt: "Allow \(pending.name)?")
        }
    }

    private static func isAutoAcceptedEdit(_ tool: String) -> Bool {
        ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool)
    }

    static func parseClaudeSession(data: Data) -> ParsedClaudeSession {
        var totalInput = 0
        var totalOutput = 0
        var totalCost: Double?
        var pending: [String: (name: String, question: String?)] = [:]
        var pendingOrder: [String] = []
        // One turn spans several content-block lines that repeat the same cumulative usage;
        // counting each inflated totals ~78%.
        var seenMessages: Set<String> = []
        var permissionMode: String?

        for lineBytes in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any] else { continue }
            // Mode-change events and user lines both carry this, and neither has a `message`,
            // so read it before the guard below skips them.
            if let mode = json["permissionMode"] as? String { permissionMode = mode }
            guard let message = json["message"] as? [String: Any] else { continue }

            if json["type"] as? String == "assistant",
               let usage = message["usage"] as? [String: Any],
               DailyActivityScanner.messageIdentity(json: json, message: message)
                   .map({ seenMessages.insert($0).inserted }) ?? true {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                // Cache reads and writes are input the model processed, and dominate a Claude
                // Code turn - the raw `input_tokens` alone reads as a few hundred tokens against
                // a real six-figure context. Counting them keeps "in" honest and consistent
                // with the cost below, which already prices all four token classes.
                totalInput += input + cacheWrite + cacheRead
                totalOutput += output
                if let model = message["model"] as? String,
                   let cost = ModelPricing.costUSD(
                       model: model,
                       inputTokens: input,
                       outputTokens: output,
                       cacheWriteTokens: cacheWrite,
                       cacheReadTokens: cacheRead
                   ) {
                    totalCost = (totalCost ?? 0) + cost
                }
            }

            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
                    pending[id] = (name, question)
                    pendingOrder.append(id)
                case "tool_result":
                    // Resolved - drop it from the pending set.
                    if let id = block["tool_use_id"] as? String { pending.removeValue(forKey: id) }
                default:
                    continue
                }
            }
        }

        var session = ParsedClaudeSession()
        session.permissionMode = permissionMode
        if totalInput > 0 || totalOutput > 0 {
            session.usage = AgentSessionUsage(cost: totalCost, tokensInput: totalInput, tokensOutput: totalOutput)
        }

        if let id = pendingOrder.last(where: { pending[$0] != nil }) {
            session.pendingTool = pending[id]
        }
        return session
    }

    // When the agent's session was last written - used to sort most-recent first.
    static func lastActivity(provider: Provider, command: String, cwd: String?) -> Date? {
        switch provider {
        case .claudeCode, .claude, .anthropic:
            return newestClaudeSession(command: command, cwd: cwd)?.modified
        case .openCode:
            return openCodeLastActivity(cwd: cwd)
        case .grok:
            return newestGrokSession(cwd: cwd)?.lastActiveAt
        case .pi:
            return PiUsageClient.latestSession(cwd: cwd)?.modified
        default:
            return nil
        }
    }

    // ~/.grok/sessions/<encoded-cwd>/<uuid>/summary.json; last_active_at picks the newest.
    private static func newestGrokSession(cwd: String?) -> (title: String?, lastActiveAt: Date?)? {
        guard let cwd else { return nil }
        let encoded = cwd.replacingOccurrences(of: "/", with: "%2F")
        let dir = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.grok/sessions/\(encoded)"
        guard let sessionIDs = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let sessions: [(title: String?, lastActiveAt: Date?)] = sessionIDs.compactMap { id in
            let summaryPath = "\(dir)/\(id)/summary.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: summaryPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let title = json["generated_title"] as? String
            let lastActiveAt = (json["last_active_at"] as? String).flatMap(parseGrokTimestamp)
            return (title, lastActiveAt)
        }
        return sessions.max { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) }
    }

    // The CLI writes microsecond precision, which ISO8601DateFormatter's 3-digit
    // fractional-seconds mode rejects. Whole seconds is all sorting needs.
    private static func parseGrokTimestamp(_ raw: String) -> Date? {
        guard let dotIndex = raw.firstIndex(of: ".") else {
            return ISO8601DateFormatter().date(from: raw)
        }
        return ISO8601DateFormatter().date(from: "\(raw[..<dotIndex])Z")
    }

    private static func openCodeLastActivity(cwd: String?) -> Date? {
        guard let cwd, let safe = safeSQLPath(cwd) else { return nil }
        let query = "SELECT MAX(time_updated) FROM session WHERE directory='\(safe)';"
        guard let raw = OpenCodeUsageClient.queryValue(query), let ms = Double(raw), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func claudeChatTitle(command: String, cwd: String?) -> String? {
        guard let file = newestClaudeSession(command: command, cwd: cwd)?.path,
              let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
            return nil
        }
        return claudeTitle(fromSessionContents: contents)
    }

    // An explicit /rename (customTitle) wins over the inferred aiTitle; both are rewritten as
    // the conversation evolves, so the last of each is current.
    static func claudeTitle(fromSessionContents contents: String) -> String? {
        var latestAI: String?
        var latestCustom: String?
        for line in contents.split(separator: "\n") {
            let text = String(line)
            if let custom = firstMatch(in: text, pattern: #""customTitle"\s*:\s*"([^"]+)""#) {
                latestCustom = custom
            }
            if let ai = firstMatch(in: text, pattern: #""aiTitle"\s*:\s*"([^"]+)""#) {
                latestAI = ai
            }
        }
        return latestCustom ?? latestAI
    }

    private static func newestClaudeSession(command: String, cwd: String?) -> (path: String, modified: Date?)? {
        // An explicit --resume path wins; otherwise pick the newest file in the project dir.
        if let resume = firstMatch(in: command, pattern: #"--resume\s+([^\s]+\.jsonl)"#) {
            return (resume, modifiedDate(resume))
        }
        if let sid = firstMatch(in: command, pattern: #"--session-id\s+([a-f0-9-]+)"#),
           let cwd, case let path = "\(projectDir(cwd))/\(sid).jsonl",
           FileManager.default.fileExists(atPath: path) {
            return (path, modifiedDate(path))
        }
        guard let cwd else { return nil }
        let dir = projectDir(cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let newest = files.filter { $0.hasSuffix(".jsonl") }
            .map { (path: "\(dir)/\($0)", modified: modifiedDate("\(dir)/\($0)")) }
            .max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        return newest
    }

    private static func openCodeChatTitle(cwd: String?) -> String? {
        guard let cwd, let safe = safeSQLPath(cwd) else { return nil }
        let query = "SELECT title FROM session WHERE directory='\(safe)' AND title != '' ORDER BY time_updated DESC LIMIT 1;"
        return OpenCodeUsageClient.queryValue(query)
    }

    // Walks the process ancestry for the hosting app. Returns the PID too: two builds of a
    // terminal share a bundle identifier, so identity alone cannot pick the right copy.
    //
    // tmux breaks the ancestry: a pane's processes descend from the detached tmux *server*
    // (parented to launchd), not from the terminal displaying them. When the walk reaches
    // the server, `terminalTTY` (the pane's tty) lets us ask tmux which client is attached
    // to this pane's session and resume from there — that client does descend from the
    // real terminal app.
    static func hostApp(ofPID pid: Int32, terminalTTY: String? = nil) -> (app: HostApp, processID: Int32)? {
        var current = pid
        for _ in 0..<8 {
            guard let output = Shell.output("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"]) else { return nil }
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
            let comm = String(parts[1]).lowercased()
            if let app = HostApp.match(comm: comm) {
                return (app, current)
            }
            if comm.contains("tmux") {
                return tmuxClientHostApp(paneTTY: terminalTTY, serverPID: current)
            }
            if ppid <= 1 { return nil }
            current = ppid
        }
        return nil
    }

    // Resolves the terminal hosting a tmux pane by finding a client attached to the pane's
    // session and walking up from that client's process. Best effort: it needs a client
    // currently attached (a detached session isn't shown anywhere to focus) and the tmux
    // binary present in a standard location.
    private static func tmuxClientHostApp(paneTTY: String?, serverPID: Int32) -> (app: HostApp, processID: Int32)? {
        guard let paneTTY,
              let tmux = tmuxBinary(),
              let socket = tmuxSocket(serverPID: serverPID) else { return nil }
        let wantedTTY = normalizedTTY(paneTTY)

        guard let session = tmuxField(tmux, socket, ["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}"])
            .first(where: { normalizedTTY($0.0) == wantedTTY })?.1 else { return nil }

        for (clientSession, clientPID) in tmuxField(tmux, socket, ["list-clients", "-F", "#{session_name}\t#{client_pid}"])
        where clientSession == session {
            // The client process is itself named `tmux`, so start one level up to avoid
            // re-detecting tmux and looping; its parent chain descends from the terminal.
            guard let pid = Int32(clientPID), let parent = parentPID(ofPID: pid) else { continue }
            if let resolved = hostApp(ofPID: parent) { return resolved }
        }
        return nil
    }

    // Splits a two-column tab-separated tmux `-F` listing into pairs. The server is targeted
    // by its own socket so a custom `-L`/`-S` server resolves like the default one.
    private static func tmuxField(_ tmux: String, _ socket: String, _ args: [String]) -> [(String, String)] {
        guard let output = Shell.output(tmux, ["-S", socket] + args) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return cols.count == 2 ? (cols[0], cols[1]) : nil
        }
    }

    private static func tmuxBinary() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // The server's listening socket, read from its open unix-domain sockets so `-S` can
    // target this exact server rather than assuming the default socket path.
    private static func tmuxSocket(serverPID: Int32) -> String? {
        guard let output = Shell.output("/usr/sbin/lsof", ["-a", "-p", "\(serverPID)", "-U", "-Fn"]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if path.contains("/tmux-") { return path }
        }
        return nil
    }

    private static func parentPID(ofPID pid: Int32) -> Int32? {
        guard let output = Shell.output("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]) else { return nil }
        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func normalizedTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    static func workingDirectory(ofPID pid: Int32) -> String? {
        guard let output = Shell.output("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        // -Fn output lists fields prefixed by a type char; the cwd path is on an "n" line.
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if !path.isEmpty { return path }
        }
        return nil
    }

    static func workingDirectory(fromCommand command: String) -> String? {
        // 1. Daemon embeds an explicit "cwd":"/abs/path" JSON fragment.
        if let cwd = firstMatch(in: command, pattern: #""cwd"\s*:\s*"([^"]+)""#) {
            return cwd
        }
        // 2. A --resume / session-file path lives under ~/.claude/projects/<encoded-cwd>/,
        //    where the dir name encodes the cwd with path separators turned into dashes.
        if let encoded = firstMatch(in: command, pattern: #"/\.claude/projects/([^/\s]+)/"#) {
            return "/" + encoded.drop(while: { $0 == "-" }).split(separator: "-").joined(separator: "/")
        }
        return nil
    }

    // ~/.claude/projects/<encoded-cwd>, where cwd path separators become dashes.
    private static func projectDir(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encoded = "-" + cwd.split(separator: "/").joined(separator: "-")
        return "\(home)/.claude/projects/\(encoded)"
    }

    private static func modifiedDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    private static func safeSQLPath(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.contains("'") else { return nil }
        return value
    }

    private nonisolated(unsafe) static var regexCache: [String: NSRegularExpression] = [:]

    private static func firstMatch(in text: String, pattern: String) -> String? {
        let regex: NSRegularExpression
        if let cached = regexCache[pattern] {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
            regexCache[pattern] = compiled
            regex = compiled
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func openCodeSessionUsage(cwd: String?) -> AgentSessionUsage? {
        guard let cwd, let safe = safeSQLPath(cwd) else { return nil }
        let query = """
        SELECT cost, tokens_input, tokens_output \
        FROM session \
        WHERE directory='\(safe)' \
        ORDER BY time_updated DESC LIMIT 1;
        """
        guard let raw = OpenCodeUsageClient.queryValue(query),
              !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let tokensInput = Int(parts[1]),
              let tokensOutput = Int(parts[2]) else { return nil }
        let cost = optionalNumber(parts[0])
        return AgentSessionUsage(cost: cost, tokensInput: tokensInput, tokensOutput: tokensOutput)
    }

    private static func piSessionUsage(cwd: String?) -> AgentSessionUsage? {
        guard let cwd else { return nil }
        guard let session = PiUsageClient.latestSession(cwd: cwd) else { return nil }
        return PiUsageClient.sessionUsage(path: session.path)
    }

    private static func claudeSessionUsage(command: String, cwd: String?) -> AgentSessionUsage? {
        guard let session = newestClaudeSession(command: command, cwd: cwd) else { return nil }

        return claudeSession(at: session.path, modified: session.modified)?.usage
    }

    // Extracted for testing; the parse lives in parseClaudeSession.
    static func claudeUsage(fromJSONLData data: Data) -> AgentSessionUsage? {
        parseClaudeSession(data: data).usage
    }

    private static func optionalNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Double(trimmed)
    }
}

// A host application Toki can name and activate. Single source of truth so the display
// name and bundle id can't drift apart (they were two switches keyed on a magic string).
struct HostApp: Hashable {
    let displayName: String
    let bundleID: String
    let matchers: [String]

    private static let all: [HostApp] = [
        HostApp(displayName: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", matchers: ["code - insiders"]),
        HostApp(displayName: "VS Code", bundleID: "com.microsoft.VSCode", matchers: ["code helper", "visual studio code"]),
        HostApp(displayName: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", matchers: ["cursor"]),
        HostApp(displayName: "ChatGPT", bundleID: "com.openai.codex", matchers: ["chatgpt"]),
        HostApp(displayName: "iTerm", bundleID: "com.googlecode.iterm2", matchers: ["iterm"]),
        HostApp(displayName: "WezTerm", bundleID: "com.github.wez.wezterm", matchers: ["wezterm"]),
        HostApp(displayName: "Alacritty", bundleID: "org.alacritty", matchers: ["alacritty"]),
        HostApp(displayName: "kitty", bundleID: "net.kovidgoyal.kitty", matchers: ["kitty"]),
        HostApp(displayName: "Ghostty", bundleID: "com.mitchellh.ghostty", matchers: ["ghostty"]),
        HostApp(displayName: "Terminal", bundleID: "com.apple.Terminal", matchers: ["terminal"]),
    ]

    static func match(comm: String) -> HostApp? {
        all.first { $0.matchers.contains { comm.contains($0) } }
    }
}
