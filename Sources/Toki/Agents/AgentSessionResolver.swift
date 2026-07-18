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
        guard let cwd else { return nil }
        let query = "SELECT MAX(time_updated) FROM session WHERE directory='\(sqlEscaped(cwd))';"
        guard let raw = OpenCodeUsageClient.queryValue(query), let ms = Double(raw), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func claudeChatTitle(command: String, cwd: String?) -> String? {
        guard let file = newestClaudeSession(command: command, cwd: cwd)?.path,
              let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
            return nil
        }
        // aiTitle is rewritten as the conversation evolves; the last one is current.
        var latest: String?
        for line in contents.split(separator: "\n") {
            if let title = firstMatch(in: String(line), pattern: #""aiTitle"\s*:\s*"([^"]+)""#) {
                latest = title
            }
        }
        return latest
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
        guard let cwd else { return nil }
        let query = "SELECT title FROM session WHERE directory='\(sqlEscaped(cwd))' AND title != '' ORDER BY time_updated DESC LIMIT 1;"
        return OpenCodeUsageClient.queryValue(query)
    }

    // Walks the process's ancestry to find the app hosting it (editor or terminal).
    static func hostApp(ofPID pid: Int32) -> HostApp? {
        var current = pid
        for _ in 0..<8 {
            guard let output = Shell.output("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"]) else { return nil }
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
            if let app = HostApp.match(comm: String(parts[1]).lowercased()) { return app }
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

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
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
