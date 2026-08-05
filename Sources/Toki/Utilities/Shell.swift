import Foundation

func shellEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

func expandedPath(_ rawPath: String) -> String {
    let path: String
    if rawPath == "~" { path = FileManager.default.homeDirectoryForCurrentUser.path }
    else if rawPath.hasPrefix("~/") {
        path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(rawPath.dropFirst(2)))
            .path
    } else {
        path = rawPath
    }
    return (path as NSString).standardizingPath
}

// A login shell (-l) sources .zprofile but not .zshrc, and the version managers most agent CLIs
// are installed through (nvm, fnm, volta, bun, pnpm, mise, asdf) put their shims on PATH from
// .zshrc. Their bin directories are spelled out here so an agent installed that way is still
// found, rather than reported as "command not found" on a machine where the user's own shell
// runs it fine. $HOME is left unexpanded so this can be interpolated into a shell command.
//
// Prepend this to the inherited PATH rather than appending it: these are the known install
// locations, and they should win over whatever an inherited PATH happens to put first. Deliberately
// absent is $HOME/node_modules/.bin, which any stray `npm install` in the home directory creates
// and fills with whatever a dependency shipped.
let agentCommandSearchPath = [
    "$HOME/.local/bin",
    "$HOME/.bun/bin",
    "$HOME/.volta/bin",
    "$HOME/.deno/bin",
    "$HOME/.cargo/bin",
    "$HOME/.npm-global/bin",
    "$HOME/.npm-packages/bin",
    "$HOME/Library/pnpm",
    "$HOME/.local/share/pnpm",
    "$HOME/.local/share/mise/shims",
    "$HOME/.asdf/shims",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
].joined(separator: ":")

enum SecureStore {
    static func write(data: Data, to url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        try data.write(to: resolved, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolved.path)
    }
}

// Single place to run a subprocess and capture stdout. Reads the output pipe BEFORE
// waiting on the process: ps/lsof output can exceed the ~64KB pipe buffer, and waiting
// first would deadlock the child against a full, unread pipe.
enum Shell {
    // nil when the process fails to launch OR exits non-zero. Returning partial stdout from a
    // failed run is the dangerous option: sqlite3 streams rows as it produces them, so a query
    // that dies halfway leaves real-looking output behind. Callers treat nil as "couldn't read",
    // which is the truth; they had no way to notice a short answer.
    static func output(_ executable: String, _ arguments: [String]) -> String? {
        try? run(executable, arguments, throwOnFailure: true)
    }

    // Throws LocalizedErrorMessage(failureMessage) if the process can't launch or exits non-zero.
    static func require(_ executable: String, _ arguments: [String], failureMessage: String) throws -> String {
        do {
            return try run(executable, arguments, throwOnFailure: true)
        } catch {
            throw LocalizedErrorMessage(failureMessage)
        }
    }

    private struct NonZeroExit: Error {}

    private static func run(_ executable: String, _ arguments: [String], throwOnFailure: Bool) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if throwOnFailure, process.terminationStatus != 0 {
            throw NonZeroExit()
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
