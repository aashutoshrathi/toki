import AppKit
import Foundation

// The Codex desktop app registers under this bundle id, which also names the ChatGPT host in
// AgentSessionResolver - one constant so the two spellings can't drift apart.
let codexAppBundleIdentifier = "com.openai.codex"

// Which install answered a usage fetch. Both cases carry resolve()'s chosen absolute path so the
// exact binary that gets invoked is loggable and testable without a second lookup.
enum CodexBinary: Equatable {
    case pathInstall(String)
    case appBundle(String)

    var executablePath: String {
        switch self {
        case .pathInstall(let path), .appBundle(let path):
            return path
        }
    }

    // Short tag for the diagnostic log line.
    var sourceTag: String {
        switch self {
        case .pathInstall: return "pathInstall"
        case .appBundle: return "appBundle"
        }
    }

    // The account-info card's "Codex CLI" value: the PATH executable that answered, or the app.
    var displayName: String {
        switch self {
        case .pathInstall(let path): return path
        case .appBundle: return "Codex.app"
        }
    }
}

enum CodexBinaryResolver {
    // Named both installs so the not-found error is actionable and testable in one place.
    static let notFoundMessage =
        "Codex isn't installed where Toki can run it. Install the Codex CLI so `codex` is on your PATH, "
        + "or install the Codex macOS app."

    // The ladder, kept pure and injectable so a real `codex` on the test runner's PATH can't bleed
    // into a test: a PATH probe result wins only when it is a single absolute path to a regular
    // executable; otherwise the first app-bundle candidate holding one; nil when nothing usable
    // exists. PATH precedence is intentional - a broken PATH install is reported, never bypassed.
    static func resolve(
        pathProbe: () throws -> String?,
        candidates: [String],
        isExecutable: (String) -> Bool
    ) rethrows -> CodexBinary? {
        if let probed = try pathProbe().flatMap(singleAbsolutePath), isExecutable(probed) {
            return .pathInstall(probed)
        }
        for directory in candidates {
            let candidate = (directory as NSString).appendingPathComponent("codex")
            if isExecutable(candidate) {
                return .appBundle(candidate)
            }
        }
        return nil
    }

    // Production entry: probe through the same login shell and search path the launch uses, gather
    // the app-bundle candidates (NSWorkspace on the main actor), then run the pure ladder - so the
    // probe and the invocation can never disagree about what `codex` resolves to.
    static func resolve() async throws -> CodexBinary? {
        let candidates = await bundleCandidateDirectories()
        return try resolve(
            pathProbe: shellPathProbe,
            candidates: candidates,
            isExecutable: isRegularExecutable
        )
    }

    // Exposed for tests: the external-executable probe against an explicit PATH expression.
    // whence -p (not `command -v`): in zsh `command -v` can name an alias or function rather than a
    // filesystem path; whence -p only ever names an external executable. `2>/dev/null || true` forces
    // exit 0 with empty output when absent, since runShell throws on any non-zero exit - a throw here
    // means the shell itself failed (login-profile error, timeout) and must surface, not be
    // misclassified as "Codex not installed".
    static func probeCodexOnPath(_ pathExpression: String) throws -> String? {
        let output = try SecretResolver.runShell("PATH=\"\(pathExpression)\" whence -p codex 2>/dev/null || true")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // A regular, executable file. Excludes directories (which are "executable" as searchable) and
    // broken symlinks, but follows symlinks so a Homebrew/npm shim still resolves.
    static func isRegularExecutable(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    private static func shellPathProbe() throws -> String? {
        try probeCodexOnPath("\(agentCommandSearchPath):$PATH")
    }

    private static func singleAbsolutePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return nil }
        return trimmed
    }

    // /Contents/Resources of every registered Codex.app followed by the two standard install
    // locations, deduplicated in order. Enumerating all registered URLs means one broken
    // registration can't hide a valid copy. NSWorkspace is MainActor-isolated under strict
    // concurrency, so only the lookup hops to the main actor and just its results cross back.
    private static func bundleCandidateDirectories() async -> [String] {
        let registered = await MainActor.run { registeredCodexResourceDirectories() }
        let literals = [
            "/Applications/Codex.app/Contents/Resources",
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources"
        ]
        var seen = Set<String>()
        return (registered + literals).filter { seen.insert($0).inserted }
    }

    @MainActor
    private static func registeredCodexResourceDirectories() -> [String] {
        NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: codexAppBundleIdentifier)
            .map { $0.appendingPathComponent("Contents/Resources").path }
    }
}
