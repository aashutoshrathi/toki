import Foundation

// Derives a human-friendly agent name from a process command line by recovering
// the working directory it runs in. The project name (last path component of the
// cwd) is the reliable distinguishing signal across Claude Code sessions - session
// files carry no dependable conversation title.
enum AgentSessionResolver {
    // Returns the last path component of the agent's working directory, or nil when it
    // can't be recovered. Tries the (free) command string first, then falls back to
    // asking the kernel for the process's actual cwd via lsof - most agents (bare
    // `claude`, editor-hosted) carry no directory hint in their args.
    static func projectName(pid: Int32, command: String) -> String? {
        let cwd = workingDirectory(fromCommand: command) ?? workingDirectory(ofPID: pid)
        guard let cwd else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
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
