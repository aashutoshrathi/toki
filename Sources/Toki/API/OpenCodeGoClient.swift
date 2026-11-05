import Foundation

// OpenCode Go is a subscription with the same shape as Codex: a rolling 5-hour window, a
// weekly one and a monthly one, each reporting how much of its allowance is used. The local
// OpenCode server already proxies those figures from the Console, so Toki asks the CLI for
// them (`opencode api get /api/experimental/usage/limits`) instead of re-implementing Console
// sign-in against an endpoint OpenCode hasn't documented. Everything here is optional: a
// BYO-key OpenCode install with no Go subscription keeps the local-spend card it always had.
struct OpenCodeGoLimits: Equatable {
    struct Window: Equatable {
        var label: String
        var percentUsed: Int
        var resetsAt: Date?
        var limited: Bool
    }

    static let rollingDuration: TimeInterval = 5 * 3600
    static let weeklyDuration: TimeInterval = 7 * 86_400
    static let monthlyDuration: TimeInterval = 30 * 86_400

    var workspaceName: String?
    var windows: [Window] = []

    var hasUsage: Bool { !windows.isEmpty }

    init(json: Any) {
        guard let root = json as? [String: Any] else { return }
        // `opencode api` wraps the response as {"location": ..., "data": ...}; accept the bare
        // payload too so a future CLI that prints the data directly still parses.
        let payload = (root["data"] as? [String: Any]) ?? root
        workspaceName = (payload["workspace"] as? [String: Any])?["name"] as? String
        guard let go = payload["go"] as? [String: Any] else { return }

        appendWindow("5h", go["rolling"])
        appendWindow("7d", go["weekly"])
        appendWindow("30d", go["monthly"])
    }

    private mutating func appendWindow(_ label: String, _ raw: Any?) {
        guard let window = raw as? [String: Any],
              let used = optionalNumber(window["percent"]) else { return }
        let limited = window["limited"] as? Bool ?? false
        let clamped = limited ? 100 : max(0, min(100, used))
        windows.append(Window(
            label: label,
            percentUsed: Int(clamped.rounded()),
            resetsAt: resetDate(window["resetsAt"]),
            limited: limited
        ))
    }

    var windowsAsRateLimits: [RateLimitWindow] {
        windows.map { window in
            RateLimitWindow(
                label: window.label,
                percentLeft: max(0, 100 - window.percentUsed),
                resetHint: window.resetsAt.map { "resets in \(resetDescription(for: $0))" },
                resetAt: window.resetsAt,
                duration: Self.duration(for: window.label)
            )
        }
    }

    private static func duration(for label: String) -> TimeInterval {
        switch label {
        case "5h": return rollingDuration
        case "7d": return weeklyDuration
        default: return monthlyDuration
        }
    }
}

enum OpenCodeGoClient {
    // The official installer puts the CLI under ~/.opencode/bin, which is not on the search
    // path the agent detectors use, so name it here before falling back to the usual spots.
    static let searchPath = ["$HOME/.opencode/bin", agentCommandSearchPath].joined(separator: ":")

    static let limitsPath = "/api/experimental/usage/limits"

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var cachedBinary: String?

    // The CLI call is a subprocess (~0.5s), so re-reading on every refresh would be wasteful
    // for a number that moves slowly. A minute matches what OpenCode's own usage plugin polls.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (fetchedAt: Date, limits: OpenCodeGoLimits?)?
    private static let cacheLifetime: TimeInterval = 60

    // Reads the Go allowance, or nil when there is nothing to read: OpenCode not installed,
    // its background server not running, no Go subscription, or an older CLI without the
    // endpoint. None of those are errors worth surfacing - the local usage card still stands.
    static func limits(now: Date = Date()) -> OpenCodeGoLimits? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache, now.timeIntervalSince(cache.fetchedAt) < cacheLifetime {
            return cache.limits
        }
        let fetched = fetch()
        cache = (now, fetched)
        return fetched
    }

    private static func fetch() -> OpenCodeGoLimits? {
        guard let binary = resolvedBinary(),
              let output = Shell.output(binary, ["api", "get", limitsPath], cwd: NSHomeDirectory()) else {
            return nil
        }
        return parse(output: output)
    }

    static func resolvedBinary() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let cachedBinary { return cachedBinary }
        guard let resolved = try? OpenCodeBinaryResolver.resolve() else { return nil }
        cachedBinary = resolved
        return resolved
    }

    // Split from the subprocess so tests can parse a recorded response.
    static func parse(output: String?) -> OpenCodeGoLimits? {
        guard let output,
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let limits = OpenCodeGoLimits(json: json)
        return limits.hasUsage ? limits : nil
    }
}

enum OpenCodeBinaryResolver {
    // A single absolute path to a regular executable, or nil. Kept pure so a test can drive the
    // ladder without a real install answering.
    static func resolve(pathProbe: () throws -> String?, isExecutable: (String) -> Bool) rethrows -> String? {
        guard let probed = try pathProbe()?.trimmingCharacters(in: .whitespacesAndNewlines),
              probed.hasPrefix("/"),
              !probed.contains("\n"),
              isExecutable(probed) else {
            return nil
        }
        return probed
    }

    static func resolve() throws -> String? {
        try resolve(pathProbe: shellPathProbe, isExecutable: CodexBinaryResolver.isRegularExecutable)
    }

    // `whence -p` only ever names an external executable; `2>/dev/null || true` keeps a missing
    // CLI from turning into a thrown shell error.
    private static func shellPathProbe() throws -> String? {
        let output = try SecretResolver.runShell("PATH=\"\(OpenCodeGoClient.searchPath):$PATH\" whence -p opencode 2>/dev/null || true")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
