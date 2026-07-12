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
        default:
            return nil
        }
    }

    private static func claudeChatTitle(command: String, cwd: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Prefer the explicit session id from args; else the newest session in the project dir.
        let sessionFile: String?
        if let sid = firstMatch(in: command, pattern: #"--session-id\s+([a-f0-9-]+)"#) {
            sessionFile = firstMatch(in: command, pattern: #"(/[^\s]*\#(sid)\.jsonl)"#)
                ?? findSessionFile(sid: sid, home: home, cwd: cwd)
        } else if let resume = firstMatch(in: command, pattern: #"--resume\s+([^\s]+\.jsonl)"#) {
            sessionFile = resume
        } else {
            sessionFile = newestSessionFile(home: home, cwd: cwd)
        }
        guard let file = sessionFile, let contents = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        // aiTitle is rewritten as the conversation evolves; the last one is current.
        var latest: String?
        for line in contents.split(separator: "\n") {
            if let title = firstMatch(in: String(line), pattern: #""aiTitle"\s*:\s*"([^"]+)""#) {
                latest = title
            }
        }
        return latest
    }

    private static func findSessionFile(sid: String, home: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let encoded = "-" + cwd.split(separator: "/").joined(separator: "-")
        let path = "\(home)/.claude/projects/\(encoded)/\(sid).jsonl"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func newestSessionFile(home: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let encoded = "-" + cwd.split(separator: "/").joined(separator: "-")
        let dir = "\(home)/.claude/projects/\(encoded)"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let jsonls = files.filter { $0.hasSuffix(".jsonl") }.map { "\(dir)/\($0)" }
        return jsonls.max { lhs, rhs in
            let l = (try? fm.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? nil
            let r = (try? fm.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? nil
            return (l ?? .distantPast) < (r ?? .distantPast)
        }
    }

    private static func openCodeChatTitle(cwd: String?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let db = "\(home)/.local/share/opencode/opencode.db"
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let escaped = cwd.replacingOccurrences(of: "'", with: "''")
        let query = "SELECT title FROM session WHERE directory='\(escaped)' AND title != '' ORDER BY time_updated DESC LIMIT 1;"
        guard let output = try? shellOutput(executable: "/usr/bin/sqlite3", arguments: ["-readonly", db, query]) else { return nil }
        let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // Walks the process's ancestry to name the app hosting it (editor or terminal).
    // Returns a friendly name ("VS Code", "iTerm", "Terminal") or nil if unrecognised.
    static func hostApp(ofPID pid: Int32) -> String? {
        var current = pid
        for _ in 0..<8 {
            guard let output = try? shellOutput(
                executable: "/bin/ps",
                arguments: ["-o", "ppid=,comm=", "-p", "\(current)"]
            ) else { return nil }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
            let comm = String(parts[1]).lowercased()
            if let app = friendlyHostName(comm) { return app }
            if ppid <= 1 { return nil }
            current = ppid
        }
        return nil
    }

    private static func friendlyHostName(_ comm: String) -> String? {
        if comm.contains("code - insiders") { return "VS Code Insiders" }
        if comm.contains("code helper") || comm.contains("visual studio code") || comm == "code" || comm.contains("electron") && comm.contains("code") { return "VS Code" }
        if comm.contains("cursor") { return "Cursor" }
        if comm.contains("chatgpt") { return "ChatGPT" }
        if comm.contains("iterm") { return "iTerm" }
        if comm.contains("wezterm") { return "WezTerm" }
        if comm.contains("alacritty") { return "Alacritty" }
        if comm.contains("kitty") { return "kitty" }
        if comm.contains("ghostty") { return "Ghostty" }
        if comm.contains("terminal") { return "Terminal" }
        return nil
    }

    // Bundle identifier for a resolved host app, so navigation can activate the exact app.
    static func bundleID(forHostApp host: String) -> String? {
        switch host {
        case "VS Code Insiders": return "com.microsoft.VSCodeInsiders"
        case "VS Code": return "com.microsoft.VSCode"
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "ChatGPT": return "com.openai.codex"
        case "iTerm": return "com.googlecode.iterm2"
        case "WezTerm": return "com.github.wez.wezterm"
        case "Alacritty": return "org.alacritty"
        case "kitty": return "net.kovidgoyal.kitty"
        case "Ghostty": return "com.mitchellh.ghostty"
        case "Terminal": return "com.apple.Terminal"
        default: return nil
        }
    }

    static func workingDirectory(ofPID pid: Int32) -> String? {
        guard let output = try? shellOutput(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        ) else { return nil }
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
        if let projectDir = firstMatch(in: command, pattern: #"/\.claude/projects/([^/\s]+)/"#) {
            return decodeProjectDir(projectDir)
        }

        return nil
    }

    // "-Users-aashutosh-Code-tokenbar" -> "/Users/aashutosh/Code/tokenbar".
    // Claude encodes the absolute cwd by replacing "/" with "-", so the leading dash
    // is the root slash. Segments that legitimately contain dashes are not recoverable,
    // but the last component (the project name) is what we surface and it round-trips.
    private static func decodeProjectDir(_ encoded: String) -> String {
        "/" + encoded.drop(while: { $0 == "-" }).split(separator: "-").joined(separator: "/")
    }

    private static func shellOutput(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting to avoid a pipe-buffer deadlock (see ActiveAgentScanner).
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}
