import Foundation

// `Toki status` (and `Toki status --json`) reads the cache the running app writes after
// every refresh (see StatusCache.swift) and prints it, then exits - it never launches the
// menu bar app or does a live fetch, so it's fast enough to call from a shell prompt.
// Wired in from main.swift, same pattern as UpdateInstaller's --install-update helper.
enum StatusCommand {
    private static let staleAfter: TimeInterval = 15 * 60
    private static let defaultWatchInterval: TimeInterval = 5

    private enum Format {
        case text, compact, json
    }

    // Returns an exit code if `arguments` requested the status command, or nil if the
    // caller should continue into the normal menu bar app launch.
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[1] == "status" else { return nil }
        let tokens = Array(arguments.dropFirst(2))

        if tokens.contains("--help") || tokens.contains("-h") {
            printHelp()
            return 0
        }

        let flags = tokens.filter { $0.hasPrefix("-") }
        // The first bare word is a provider/account filter (e.g. `Toki status codex`).
        let filter = tokens.first { !$0.hasPrefix("-") }
        let format: Format = flags.contains("--json") ? .json
            : flags.contains("--compact") ? .compact : .text

        if let interval = watchInterval(from: flags) {
            runWatch(interval: interval, filter: filter, format: format)
            return 0
        }

        return runOnce(filter: filter, format: format, wantsExitCode: flags.contains("--exit-code"))
    }

    private static func runOnce(filter: String?, format: Format, wantsExitCode: Bool) -> Int32 {
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

        let accounts = filteredAccounts(cache.accounts, filter: filter)
        if let filter, accounts.isEmpty {
            printErr("No account matches \"\(filter)\".")
            return 1
        }

        var exitCode: Int32 = 0
        switch format {
        case .json:
            if !printJSON(filteredCache(cache, accounts: accounts)) { exitCode = 1 }
        case .compact:
            printCompact(cache, accounts: accounts)
        case .text:
            printText(cache, accounts: accounts)
        }

        let age = Date().timeIntervalSince(cache.updatedAt)
        if age > staleAfter {
            printErr("(stale - last updated \(Int(age / 60))m ago; is Toki running?)")
        }

        // Opt-in scriptable status: exit 2 when every tracked quota among the matching
        // accounts is exhausted, so `Toki status codex --exit-code || notify` is possible
        // without parsing output. Reserved exit 1 stays "couldn't read status".
        if wantsExitCode, exitCode == 0, allTrackedQuotaExhausted(accounts) {
            return 2
        }
        return exitCode
    }

    // Redraws the (filtered) status every `interval` seconds until interrupted, reloading the
    // cache each tick so it tracks the running app's refreshes live. Unlike runOnce, a missing
    // cache isn't fatal here - it just waits, since the app may not have written one yet.
    private static func runWatch(interval: TimeInterval, filter: String?, format: Format) {
        while true {
            print("\u{1b}[2J\u{1b}[H", terminator: "")  // clear screen, home cursor
            if let cache = StatusCacheStore.load() {
                let accounts = filteredAccounts(cache.accounts, filter: filter)
                if let filter, accounts.isEmpty {
                    print("No account matches \"\(filter)\".")
                } else {
                    switch format {
                    case .json: _ = printJSON(filteredCache(cache, accounts: accounts))
                    case .compact: printCompact(cache, accounts: accounts)
                    case .text: printText(cache, accounts: accounts)
                    }
                    let age = max(0, Int(Date().timeIntervalSince(cache.updatedAt)))
                    print("\nupdated \(age)s ago · refreshing every \(Int(interval))s · Ctrl-C to stop")
                }
            } else {
                print("Waiting for Toki to write a status snapshot... (open the app)")
            }
            fflush(stdout)  // flush each frame so redirected/piped output isn't lost to buffering
            Thread.sleep(forTimeInterval: interval)
        }
    }

    // Matches a provider (rawValue or display name) or account name, case-insensitively, as a
    // substring - so `pi`, `codex`, `claude`, or a configured account nickname all work.
    static func filteredAccounts(_ accounts: [StatusCacheEntry], filter: String?) -> [StatusCacheEntry] {
        guard let filter = filter?.lowercased(), !filter.isEmpty else { return accounts }
        return accounts.filter { account in
            account.name.lowercased().contains(filter)
                || account.provider.rawValue.lowercased().contains(filter)
                || account.provider.displayName.lowercased().contains(filter)
        }
    }

    // True when there is at least one quota-bearing account among these and all of them are
    // effectively empty - mirrors the app's own menu-bar exhaustion check.
    static func allTrackedQuotaExhausted(_ accounts: [StatusCacheEntry]) -> Bool {
        let tracked = accounts.filter { !$0.isError && $0.remainingRatio != nil }
        guard !tracked.isEmpty else { return false }
        return tracked.allSatisfy { ($0.remainingRatio ?? 1) <= 0.01 }
    }

    private static func filteredCache(_ cache: StatusCache, accounts: [StatusCacheEntry]) -> StatusCache {
        var copy = cache
        copy.accounts = accounts
        let providers = Set(accounts.map(\.provider))
        copy.menuBarEntries = cache.menuBarEntries.filter { providers.contains($0.provider) }
        return copy
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
    private static func printCompact(_ cache: StatusCache, accounts: [StatusCacheEntry]) {
        let providers = Set(accounts.map(\.provider))
        let entries = cache.menuBarEntries.filter { providers.contains($0.provider) }
        guard !entries.isEmpty else {
            print(cache.recommendationTitle)
            return
        }
        print(entries.map { "\($0.leadingText ?? $0.provider.displayName) \($0.value)" }.joined(separator: "  "))
    }

    private static func printText(_ cache: StatusCache, accounts: [StatusCacheEntry]) {
        guard !accounts.isEmpty else {
            print(cache.recommendationTitle)
            return
        }
        for account in accounts {
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

    private static func printHelp() {
        print("""
        Toki status - print cached account usage (never fetches live)

        Usage:
          Toki status [filter] [options]

        Arguments:
          filter           Only show accounts matching a provider (pi, codex, claude, ...)
                           or account name, case-insensitive substring.

        Options:
          --compact        Single line matching the menu bar icon, for prompts/status bars.
          --json           Full snapshot as JSON.
          --watch[=secs]   Redraw live every N seconds (default \(Int(defaultWatchInterval))); Ctrl-C to stop.
          --exit-code      Exit 2 when all matching tracked quota is exhausted (else 0).
          -h, --help       Show this help.

        Examples:
          Toki status                 # one line per account
          Toki status pi              # just the Pi account
          Toki status --compact       # prompt-friendly single line
          Toki status codex --exit-code || echo "codex tapped out"
        """)
    }

    // nil when --watch wasn't passed. Accepts `--watch` (default interval) or `--watch=N`.
    private static func watchInterval(from flags: [String]) -> TimeInterval? {
        guard let flag = flags.first(where: { $0 == "--watch" || $0.hasPrefix("--watch=") }) else { return nil }
        if let equals = flag.firstIndex(of: "="), let value = TimeInterval(flag[flag.index(after: equals)...]), value > 0 {
            return value
        }
        return defaultWatchInterval
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
