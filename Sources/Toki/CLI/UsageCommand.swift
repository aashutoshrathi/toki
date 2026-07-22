import Foundation

/// Carries the scan result out of the detached task. Locked rather than `nonisolated(unsafe)`
/// so the hand-off is structurally safe instead of safe by assertion.
private final class ActivityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DailyActivity] = []
    private var storedUnreadable: [Provider] = []

    func store(_ activity: [DailyActivity], unreadable providers: [Provider]) {
        lock.lock()
        stored = activity
        storedUnreadable = providers
        lock.unlock()
    }

    var value: [DailyActivity] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var unreadable: [Provider] {
        lock.lock()
        defer { lock.unlock() }
        return storedUnreadable
    }
}

/// `Toki usage` - the daily activity heatmap, in the terminal.
///
/// Unlike `Toki status`, this does not read the status cache: it scans the same session stores
/// the app does, so it works with the app closed and reports history from before Toki was
/// installed.
enum UsageCommand {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[1] == "usage" else { return nil }
        let flags = Array(arguments.dropFirst(2))

        if flags.contains("-h") || flags.contains("--help") {
            printHelp()
            return 0
        }

        let days = dayCount(from: flags) ?? 30
        let provider = providerFilter(from: flags)
        let wantsJSON = flags.contains("--json")

        // The scan is async; the CLI is not. A semaphore is the honest bridge for a one-shot
        // command - there is nothing else for this process to do meanwhile. The result is
        // handed over through a lock rather than a captured var so it crosses the task boundary
        // without a data race.
        let gate = DispatchSemaphore(value: 0)
        let box = ActivityBox()
        Task {
            let scanned = await DailyActivityScanner.scan(dayCount: days)
            box.store(scanned.activities, unreadable: scanned.unreadable)
            gate.signal()
        }
        gate.wait()
        let activity = box.value
        // Reported on stderr so it never contaminates --json or a piped chart, and exits
        // non-zero: a script must be able to tell "no work" from "could not read".
        let incomplete = !box.unreadable.isEmpty
        if incomplete {
            let names = box.unreadable.map { $0.displayName }.joined(separator: ", ")
            FileHandle.standardError.write(Data("warning: couldn't read session history for \(names)\n".utf8))
        }

        var resolved: Provider?
        if let name = provider {
            let present = Set(activity.map(\.provider))
            resolved = resolveProvider(name, among: present)
            guard resolved != nil else {
                let available = present.map(\.displayName).sorted().joined(separator: ", ")
                FileHandle.standardError.write(Data(
                    "No provider matching \"\(name)\". Found: \(available.isEmpty ? "none" : available)\n".utf8
                ))
                return 1
            }
        }

        let filtered = resolved.map { wanted in activity.filter { $0.provider == wanted } } ?? activity
        if wantsJSON {
            guard printJSON(filtered, days: days) else { return 1 }
            return incomplete ? 1 : 0
        }
        printChart(filtered, days: days, provider: resolved)
        return incomplete ? 1 : 0
    }

    // Resolved against the providers actually present, not every case in the enum. Matching the
    // enum meant "claude" resolved to `.claude` - which the scanner never emits - before
    // `.claudeCode`, so the filter silently returned nothing. Exact rawValue wins, then a
    // display-name prefix, then a substring; ties broken by display name so it is deterministic.
    static func resolveProvider(_ name: String, among present: Set<Provider>) -> Provider? {
        let ordered = present.sorted { $0.displayName < $1.displayName }
        return ordered.first { $0.rawValue.lowercased() == name }
            ?? ordered.first { $0.displayName.lowercased().hasPrefix(name) }
            ?? ordered.first { $0.displayName.lowercased().contains(name) }
    }

    private static func dayPhrase(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    // MARK: - Rendering

    private static func printChart(_ activity: [DailyActivity], days: Int, provider: Provider?) {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: activity) { calendar.startOfDay(for: $0.day) }
        guard !byDay.isEmpty else {
            print("No agent activity found in the last \(dayPhrase(days)).")
            print("Checked Claude Code, OpenCode and Pi session history.")
            return
        }

        let totals = byDay.mapValues { entries in entries.reduce(0) { $0 + $1.tokens } }
        let distinct = Set(totals.values).sorted()
        let today = calendar.startOfDay(for: Date())

        let scope = provider.map { "\($0.displayName) - " } ?? ""
        print("\(scope)last \(dayPhrase(days))\n")

        // Week rows, weekday columns, oldest first - the same shape as the app's grid so the two
        // read the same way.
        var line = "  "
        for symbol in ["S", "M", "T", "W", "T", "F", "S"] { line += " \(symbol) " }
        print(line)

        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let leading = calendar.component(.weekday, from: start) - 1
        var column = 0
        var row = "  "
        row += String(repeating: "   ", count: leading)
        column = leading

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            row += " \(cell(for: totals[date], distinct: distinct)) "
            column += 1
            if column == 7 {
                print(row)
                row = "  "
                column = 0
            }
        }
        if column > 0 { print(row) }

        print("\n  \(legend())")
        summary(totals: totals, activity: activity)
    }

    /// A block glyph shaded by the day's rank among active days - the same ranking the app uses,
    /// so a quiet day and a busy one are always different, whatever the absolute numbers are.
    private static func cell(for tokens: Int?, distinct: [Int]) -> String {
        guard let tokens else { return dim("·") }
        let level = rank(tokens, among: distinct, steps: shades.count)
        return colored(shades[level], ansi: ansiShades[level])
    }

    /// Four block weights rather than colour alone, so the chart survives a pipe, a log file, or
    /// a terminal with no colour support - the shape stays readable in plain text.
    private static let shades = ["░", "▒", "▓", "█"]
    private static let ansiShades = [153, 111, 33, 21]

    private static func rank(_ value: Int, among distinct: [Int], steps: Int) -> Int {
        ActivityRank.level(value, among: distinct, steps: steps)
    }

    private static func legend() -> String {
        let blocks = zip(shades, ansiShades).map { colored($0.0, ansi: $0.1) }.joined(separator: " ")
        return "\(dim("less")) \(blocks) \(dim("more"))   \(dim("· no usage"))"
    }

    private static func summary(totals: [Date: Int], activity: [DailyActivity]) {
        let tokens = totals.values.reduce(0, +)
        let cost = activity.reduce(0) { $0 + $1.cost }
        let busiest = totals.max { $0.value < $1.value }

        var lines: [String] = []
        let activeDays = totals.count == 1 ? "day" : "days"
        lines.append("  \(bold(formatCompact(Double(tokens)))) tokens across \(bold("\(totals.count)")) active \(activeDays)")
        if cost > 0 {
            lines.append("  \(bold(formatUSD(cost))) estimated")
        }
        if let busiest {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            lines.append("  busiest \(formatter.string(from: busiest.key)) at \(formatCompact(Double(busiest.value))) tokens")
        }

        // Per provider, heaviest first - the split the heatmap's hover shows in the app.
        let perProvider = Dictionary(grouping: activity, by: \.provider)
            .map { (provider: $0.key, tokens: $0.value.reduce(0) { $0 + $1.tokens }, cost: $0.value.reduce(0) { $0 + $1.cost }) }
            .sorted { $0.tokens > $1.tokens }
        if perProvider.count > 1 {
            lines.append("")
            // Both columns padded, so the figures line up rather than stepping with the width of
            // the provider name beside them.
            let tokenColumn = perProvider.map { formatCompact(Double($0.tokens)) }
            let widest = tokenColumn.map(\.count).max() ?? 0
            for (entry, tokens) in zip(perProvider, tokenColumn) {
                var text = "  \(entry.provider.displayName.padding(toLength: 12, withPad: " ", startingAt: 0))"
                text += String(repeating: " ", count: max(widest - tokens.count, 0)) + tokens
                if entry.cost > 0 { text += "   \(formatUSD(entry.cost))" }
                lines.append(text)
            }
        }
        print("\n" + lines.joined(separator: "\n"))
    }

    private static func printJSON(_ activity: [DailyActivity], days: Int) -> Bool {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let byDay = Dictionary(grouping: activity) { calendar.startOfDay(for: $0.day) }
        let payload: [[String: Any]] = byDay.keys.sorted().map { day in
            let entries = byDay[day] ?? []
            return [
                "date": formatter.string(from: day),
                "tokens": entries.reduce(0) { $0 + $1.tokens },
                "cost": entries.reduce(0) { $0 + $1.cost },
                "providers": entries.sorted { $0.tokens > $1.tokens }.map {
                    ["provider": $0.provider.rawValue, "tokens": $0.tokens, "cost": $0.cost]
                },
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["days": days, "activity": payload],
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Couldn't encode usage as JSON\n".utf8))
            return false
        }
        print(text)
        return true
    }

    // MARK: - Terminal

    /// Colour is suppressed when stdout is not a terminal, or when NO_COLOR is set. Piping the
    /// chart into a file should not fill it with escape sequences, and the block glyphs already
    /// carry the shading on their own.
    private static var supportsColor: Bool {
        guard ProcessInfo.processInfo.environment["NO_COLOR"] == nil else { return false }
        guard ProcessInfo.processInfo.environment["TERM"] != "dumb" else { return false }
        return isatty(FileHandle.standardOutput.fileDescriptor) == 1
    }

    private static func colored(_ text: String, ansi: Int) -> String {
        supportsColor ? "\u{1B}[38;5;\(ansi)m\(text)\u{1B}[0m" : text
    }

    private static func dim(_ text: String) -> String {
        supportsColor ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }

    private static func bold(_ text: String) -> String {
        supportsColor ? "\u{1B}[1m\(text)\u{1B}[0m" : text
    }

    // MARK: - Arguments

    private static func dayCount(from flags: [String]) -> Int? {
        for flag in flags where flag.hasPrefix("--days=") {
            if let value = Int(flag.dropFirst("--days=".count)) {
                return min(max(value, 1), 365)
            }
        }
        return nil
    }

    /// The raw filter word. Resolving it to a Provider is deferred until the scan has run, so it
    /// can be matched against providers that actually reported data.
    private static func providerFilter(from flags: [String]) -> String? {
        flags.first { !$0.hasPrefix("-") }?.lowercased()
    }

    private static func printHelp() {
        print("""
        Toki usage - daily agent activity, read from local session history

        Reads Claude Code, OpenCode and Pi session stores directly, so it works with
        the app closed and covers history from before Toki was installed.

        Usage:
          Toki usage [provider] [options]

        Arguments:
          provider         Only count one provider (claude, opencode, pi).

        Options:
          --days=N         Window to chart, 1-365 (default 30).
          --json           Per-day totals as JSON, for scripting.
          -h, --help       Show this help.

        Examples:
          Toki usage                  # last 30 days
          Toki usage --days=90        # a quarter
          Toki usage claude           # Claude Code only
          Toki usage --json | jq '.activity[-1]'
        """)
    }
}
