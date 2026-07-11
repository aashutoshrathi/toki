import Foundation

// OpenCode stores usage locally in a SQLite database (opencode.db). It's BYO-key, so
// there is no provider-side quota - we surface today's spend and token counts plus an
// all-time total, read via the system sqlite3 CLI (matching how the app shells out to
// ps/lsof rather than linking a new dependency).
struct OpenCodeUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let dbPath = OpenCodeUsageClient.databasePath()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw LocalizedErrorMessage("OpenCode database not found at \(dbPath)")
        }

        let today = try query(
            db: dbPath,
            sql: "SELECT IFNULL(SUM(cost),0), IFNULL(SUM(tokens_input),0), IFNULL(SUM(tokens_output),0) FROM session WHERE time_updated/1000 >= strftime('%s','now','start of day');"
        )
        let total = try query(
            db: dbPath,
            sql: "SELECT IFNULL(SUM(cost),0), IFNULL(SUM(tokens_input),0), IFNULL(SUM(tokens_output),0), COUNT(*) FROM session;"
        )

        let todayCost = today.value(0)
        let todayIn = today.value(1)
        let todayOut = today.value(2)
        let totalCost = total.value(0)
        let sessionCount = Int(total.value(3))

        var metrics: [MetricLine] = []
        metrics.append(MetricLine(label: "Today", value: "\(formatCompact(todayIn)) in / \(formatCompact(todayOut)) out"))
        metrics.append(MetricLine(label: "Total", value: formatUSD(totalCost)))
        metrics.append(MetricLine(label: "Sessions", value: "\(sessionCount)"))

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .openCode,
            primary: todayCost > 0 ? "\(formatUSD(todayCost)) today" : "No usage today",
            subtitle: "OpenCode - local usage",
            remainingRatio: nil,
            metrics: metrics,
            isError: false
        )
    }

    private struct Row {
        let columns: [Double]
        func value(_ index: Int) -> Double { index < columns.count ? columns[index] : 0 }
    }

    private func query(db: String, sql: String) throws -> Row {
        let output = try OpenCodeUsageClient.sqliteOutput(db: db, sql: sql)
        let columns = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return Row(columns: columns)
    }

    // OpenCode isn't a configured account - if its local database exists we surface it
    // automatically (mirroring how running agents are auto-detected), without writing
    // anything into the user's config file.
    static let autoDetectedID = "opencode-auto"

    static func autoDetectedAccount() -> AccountConfig? {
        guard FileManager.default.fileExists(atPath: databasePath()) else { return nil }
        return AccountConfig(id: autoDetectedID, name: "OpenCode", provider: .openCode)
    }

    static func databasePath() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"], !override.isEmpty {
            return (override as NSString).appendingPathComponent("opencode.db")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/opencode/opencode.db"
    }

    private static func sqliteOutput(db: String, sql: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", db, sql]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting to avoid a pipe-buffer deadlock (see ActiveAgentScanner).
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalizedErrorMessage("Failed to read OpenCode usage database")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
