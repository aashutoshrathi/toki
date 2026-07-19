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
    // Best-effort: returns stdout regardless of exit status (nil only if launch fails).
    static func output(_ executable: String, _ arguments: [String]) -> String? {
        try? run(executable, arguments, throwOnFailure: false)
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
