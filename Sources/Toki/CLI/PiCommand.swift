import Foundation

// `Toki pi` prints Pi's local spend breakdown (today / this week / this month / all time).
// Unlike `Toki status`, this doesn't read the running app's cache - Pi usage is entirely local
// JSONL, so it's computed on the spot via PiUsageClient.aggregate(). That means it works even
// when the menu bar app has never run, and always reflects the session files as they are now.
enum PiCommand {
    private struct Report: Codable {
        let todayCost: Double
        let weekCost: Double
        let monthCost: Double
        let allTimeCost: Double
        let todayInputTokens: Double
        let todayOutputTokens: Double
        let todayCacheReadTokens: Double
        let todayCacheWriteTokens: Double
        let sessions: Int
    }

    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[1] == "pi" else { return nil }
        let tokens = Array(arguments.dropFirst(2))

        if tokens.contains("--help") || tokens.contains("-h") {
            printHelp()
            return 0
        }

        let totals: PiUsageClient.Totals
        do {
            totals = try PiUsageClient.aggregate()
        } catch {
            printErr(error.localizedDescription)
            return 1
        }

        if tokens.contains("--json") {
            return printJSON(totals) ? 0 : 1
        }
        printText(totals)
        return 0
    }

    private static func printText(_ totals: PiUsageClient.Totals) {
        print("Pi - local usage (estimated)")
        print("  Today:      \(formatUSD(totals.todayCost))  (\(formatCompact(totals.todayInput)) in / \(formatCompact(totals.todayOutput)) out)")
        print("  This week:  \(formatUSD(totals.weekCost))")
        print("  This month: \(formatUSD(totals.monthCost))")
        print("  All time:   \(formatUSD(totals.allTimeCost))")
        print("  Sessions:   \(totals.sessionCount)")
    }

    private static func printJSON(_ totals: PiUsageClient.Totals) -> Bool {
        let report = Report(
            todayCost: totals.todayCost,
            weekCost: totals.weekCost,
            monthCost: totals.monthCost,
            allTimeCost: totals.allTimeCost,
            todayInputTokens: totals.todayInput,
            todayOutputTokens: totals.todayOutput,
            todayCacheReadTokens: totals.todayCacheRead,
            todayCacheWriteTokens: totals.todayCacheWrite,
            sessions: totals.sessionCount
        )
        guard let data = try? JSONEncoder.toki.encode(report), let text = String(data: data, encoding: .utf8) else {
            printErr("Could not encode Pi usage as JSON.")
            return false
        }
        print(text)
        return true
    }

    private static func printHelp() {
        print("""
        Toki pi - print Pi's local spend breakdown (computed from session history)

        Usage:
          Toki pi [--json]

        Options:
          --json       Emit the breakdown as JSON.
          -h, --help   Show this help.

        Reads local Pi JSONL session history directly; needs no running app or Toki account.
        Session root resolves via PI_CODING_AGENT_SESSION_DIR, ~/.pi/agent/settings.json, or
        ~/.pi/agent/sessions - same as the app.
        """)
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
