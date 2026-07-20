import Foundation

// Derives a human-friendly agent name from a process command line by recovering
// the working directory it runs in. The project name (last path component of the
// cwd) is the reliable distinguishing signal across Claude Code sessions - session
// files carry no dependable conversation title.
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

    // Everything derived from one pass over a Claude session file.
    struct ParsedClaudeSession: Sendable {
        var usage: AgentSessionUsage?
        /// The tool call still awaiting a result, if any. Whether that counts as "blocked"
        /// depends on elapsed time, so the decision is deferred to the caller rather than
        /// baked in here - otherwise the cached value would expire every second.
        var pendingTool: (name: String, question: String?)?
    }

    // Session files reach tens of megabytes, and both usage and attention need the same parse.
    // Reading and decoding twice per agent per scan - which is what separate implementations
    // did - was enough JSON work to keep the agent list churning. Cached on path plus
    // modification date and size, so an unchanged file is never re-read at all.
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
        // Keep the cache from growing without bound as projects come and go.
        if claudeCache.count > 64 {
            claudeCache = claudeCache.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
        return parsed
    }

    // OpenCode records each tool invocation as a `part` row whose JSON carries a
    // state.status of running / completed / error. A part left in `running` is the same
    // signal as Claude's unresolved tool_use: the tool was invoked and nothing has come back.
    //
    // The `permission` table is not the signal it looks like - it is the persisted allow-list
    // of previously granted permissions, not a queue of pending prompts, and it stays empty
    // on a machine that has never granted one.
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

    // How long a tool call must sit unanswered before we call it "blocked". A tool that's
    // merely executing writes its result within a moment, whereas a permission prompt or an
    // open question sits indefinitely - so quiet time is what separates the two. Without this
    // the indicator would strobe on every normal tool call.
    private static let attentionQuietPeriod: TimeInterval = 10

    // Claude Code writes a tool_use block when it calls a tool and a matching tool_result once
    // the call completes. A tool_use with no result is therefore the signal for "stopped and
    // waiting": either the user is staring at a permission prompt, or the agent asked a
    // question via AskUserQuestion/ExitPlanMode and is blocked on the answer. Neither writes
    // anything further to the file until the user acts.
    //
    // Extracted for testing - `now` and `modified` are injected so the quiet-period gate can
    // be exercised without touching the clock.
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
            // Any other unanswered tool call is a pending permission prompt.
            return AgentAttention(kind: .permission, prompt: "Allow \(pending.name)?")
        }
    }

    // One pass produces both the token/cost totals and the unresolved tool call.
    static func parseClaudeSession(data: Data) -> ParsedClaudeSession {
        var totalInput = 0
        var totalOutput = 0
        var totalCost: Double?
        var pending: [String: (name: String, question: String?)] = [:]
        var pendingOrder: [String] = []
        // One assistant turn is written as several lines - one per content block - each
        // repeating the same message id and the same already-cumulative usage. Counting every
        // line inflated this session's tokens and cost by roughly 78%.
        var seenMessages: Set<String> = []

        for lineBytes in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                  let message = json["message"] as? [String: Any] else { continue }

            if json["type"] as? String == "assistant",
               let usage = message["usage"] as? [String: Any],
               DailyActivityScanner.messageIdentity(json: json, message: message)
                   .map({ seenMessages.insert($0).inserted }) ?? true {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                totalInput += input
                totalOutput += output
                if let model = message["model"] as? String,
                   let cost = ModelPricing.costUSD(
                       model: model,
                       inputTokens: input,
                       outputTokens: output,
                       cacheWriteTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
                       cacheReadTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0
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
        if totalInput > 0 || totalOutput > 0 {
            session.usage = AgentSessionUsage(cost: totalCost, tokensInput: totalInput, tokensOutput: totalOutput)
        }
        // The most recent unresolved call is the one the user is actually looking at.
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

    // ~/.grok/sessions/<percent-encoded-cwd>/<session-uuid>/summary.json - generated_title
    // is the grok CLI's own auto-generated conversation summary (rewritten as the session
    // evolves, same idea as Claude's aiTitle), and last_active_at sorts multiple sessions
    // in the same project so the most recent one wins.
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

    // Truncates the fractional-seconds portion before parsing - the CLI writes microsecond
    // precision, which ISO8601DateFormatter's fixed 3-digit fractional-seconds mode rejects,
    // and whole-second precision is all sorting/relative display needs anyway.
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

    // A user's explicit /rename (written as customTitle) always wins over the AI-inferred
    // aiTitle; the inferred title is only shown when the chat was never explicitly named. Both
    // fields are rewritten as the conversation evolves, so the last of each is the current one.
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

    // Resolves the session file once (path + mtime) so chatTitle and lastActivity share it.
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

    // Walks the process's ancestry to find the app hosting it (editor or terminal).
    //
    // Returns the host's PID alongside its identity, because the identity alone is not enough
    // to focus it: two builds of the same terminal share a bundle identifier, so looking the
    // app up by identifier can raise the wrong copy - the one without this agent's window.
    // The PID names exactly one process.
    static func hostApp(ofPID pid: Int32) -> (app: HostApp, processID: Int32)? {
        var current = pid
        for _ in 0..<8 {
            guard let output = Shell.output("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"]) else { return nil }
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
            if let app = HostApp.match(comm: String(parts[1]).lowercased()) {
                return (app, current)
            }
            if ppid <= 1 { return nil }
            current = ppid
        }
        return nil
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
        // Shares the cached parse with attention() - same file, same pass.
        return claudeSession(at: session.path, modified: session.modified)?.usage
    }

    // Extracted for testing — parses assistant-message token counts from a Claude Code
    // JSONL session file (each line is a JSON object, assistant messages carry usage).
    // Retained as the documented entry point for token/cost totals; the parse itself lives in
    // parseClaudeSession so attention and usage share a single pass over the file.
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
