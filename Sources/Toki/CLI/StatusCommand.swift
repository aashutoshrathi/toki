import Foundation

// `Toki status` (and `Toki status --json`) reads the cache the running app writes after
// every refresh (see StatusCache.swift) and prints it, then exits - it never launches the
// menu bar app or does a live fetch, so it's fast enough to call from a shell prompt.
// Wired in from main.swift, same pattern as UpdateInstaller's --install-update helper.
enum StatusCommand {
    private static let staleAfter: TimeInterval = 15 * 60

    // Returns an exit code if `arguments` requested the status command, or nil if the
    // caller should continue into the normal menu bar app launch.
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[1] == "status" else { return nil }
        let flags = Set(arguments.dropFirst(2))

        guard let cache = StatusCacheStore.load() else {
            // load() returns nil both when the file is simply missing (the common
            // first-run case) and when it exists but failed to read/decode (a partial
            // write, a schema change across an update) - those need different guidance.
            if FileManager.default.fileExists(atPath: StatusCacheStore.path) {
                printErr("Could not read the cached status at \(StatusCacheStore.path) - it may be corrupt. Reopen Toki to regenerate it.")
            } else {
                printErr("No usage data yet - open Toki at least once so it can compute a snapshot.")
            }
            return 1
        }

        var exitCode: Int32 = 0
        if flags.contains("--json") {
            if !printJSON(cache) { exitCode = 1 }
        } else if flags.contains("--compact") {
            printCompact(cache)
        } else {
            printText(cache)
        }

        let age = Date().timeIntervalSince(cache.updatedAt)
        if age > staleAfter {
            printErr("(stale - last updated \(Int(age / 60))m ago; is Toki running?)")
        }
        return exitCode
    }

    // Returns whether encoding succeeded, so callers driving this from a script (checking
    // $?, not just stdout) can tell a real failure apart from a clean run.
    private static func printJSON(_ cache: StatusCache) -> Bool {
        guard let data = try? JSONEncoder.toki.encode(cache), let text = String(data: data, encoding: .utf8) else {
            printErr("Could not encode status as JSON.")
            return false
        }
        print(text)
        return true
    }

    // Mirrors exactly what the menu bar icon currently shows (same entries, same
    // display-mode preference), so it stays consistent with what the user already sees.
    // MenuBarStatusView swaps the provider logo for leadingText (the break-suggestion
    // emoji) when quota is exhausted - text has no logo to fall back to, so it takes
    // leadingText the same way, and otherwise uses the provider name as the logo's
    // printable stand-in.
    private static func printCompact(_ cache: StatusCache) {
        guard !cache.menuBarEntries.isEmpty else {
            print(cache.recommendationTitle)
            return
        }
        print(cache.menuBarEntries.map { "\($0.leadingText ?? $0.provider.displayName) \($0.value)" }.joined(separator: "  "))
    }

    private static func printText(_ cache: StatusCache) {
        guard !cache.accounts.isEmpty else {
            print(cache.recommendationTitle)
            return
        }
        for account in cache.accounts {
            let value: String
            if account.isError {
                value = "unavailable"
            } else if let ratio = account.remainingRatio {
                value = "\(Int((ratio * 100).rounded()))% left"
            } else {
                value = account.primary
            }
            print("\(account.name): \(value)")
        }
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
