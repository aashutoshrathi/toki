import Foundation

// OpenCode stores usage locally in a SQLite database (opencode.db). It's BYO-key, so
// there is no provider-side quota - we surface today's spend and token counts plus an
// all-time total, read via the system sqlite3 CLI (matching how the app shells out to
// ps/lsof rather than linking a new dependency).
struct OpenCodeUsageClient {
    struct Totals: Equatable {
        var todayCost = 0.0
        var weekCost = 0.0
        var monthCost = 0.0
        var allTimeCost = 0.0
    }

    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let dbPath = OpenCodeUsageClient.databasePath()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            let shortPath = dbPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            throw LocalizedErrorMessage("OpenCode database not found at \(shortPath)")
        }

        // One DB open: today's figures via conditional SUMs alongside all-time totals.
        let startOfDay = "time_updated/1000 >= CAST(strftime('%s','now','localtime','start of day') AS INTEGER)"
        let row = try query(
            db: dbPath,
            sql: """
            SELECT \
            IFNULL(SUM(CASE WHEN \(startOfDay) THEN cost END),0), \
            IFNULL(SUM(CASE WHEN \(startOfDay) THEN tokens_input END),0), \
            IFNULL(SUM(CASE WHEN \(startOfDay) THEN tokens_output END),0), \
            IFNULL(SUM(cost),0), COUNT(*) FROM session;
            """
        )

        let todayCost = row.value(0)
        let todayIn = row.value(1)
        let todayOut = row.value(2)
        let totalCost = row.value(3)
        let sessionCount = Int(row.value(4))

        var metrics: [MetricLine] = []
        metrics.append(MetricLine(label: "Today", value: "\(formatCompact(todayIn)) in / \(formatCompact(todayOut)) out"))
        metrics.append(MetricLine(label: "Total", value: formatUSD(totalCost)))
        metrics.append(MetricLine(label: "Sessions", value: "\(sessionCount)"))

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .openCode,
            primary: "\(formatUSD(todayCost)) / \(formatCompact(todayIn)) in / \(formatCompact(todayOut)) out today",
            subtitle: "OpenCode - local usage",
            remainingRatio: nil,
            metrics: metrics,
            isError: false,
            menuBarValue: formatUSD(todayCost)
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
            .map { optionalNumber(String($0).trimmingCharacters(in: .whitespaces)) ?? 0 }
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

    // Aggregated cost across all sessions, bucketed by time period. Uses the same
    // calendar boundaries as PiUsageClient.aggregate() so the Analytics tab can sum them.
    static func aggregate(db dbPath: String? = nil, now: Date = Date(), calendar: Calendar = .current) throws -> Totals {
        let db = dbPath ?? databasePath()
        guard FileManager.default.fileExists(atPath: db) else {
            throw LocalizedErrorMessage("OpenCode database not found")
        }

        let startOfDay = calendar.startOfDay(for: now)
        let dayStart = Int(startOfDay.timeIntervalSince1970)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now).map { Int($0.start.timeIntervalSince1970) } ?? 0
        let monthStart = calendar.dateInterval(of: .month, for: now).map { Int($0.start.timeIntervalSince1970) } ?? 0

        let row = try Self.staticQuery(
            db: db,
            sql: """
            SELECT \
            IFNULL(SUM(CASE WHEN time_updated/1000 >= \(dayStart) THEN cost END),0), \
            IFNULL(SUM(CASE WHEN time_updated/1000 >= \(weekStart) THEN cost END),0), \
            IFNULL(SUM(CASE WHEN time_updated/1000 >= \(monthStart) THEN cost END),0), \
            IFNULL(SUM(cost),0) FROM session;
            """
        )

        return Totals(
            todayCost: row.value(0),
            weekCost: row.value(1),
            monthCost: row.value(2),
            allTimeCost: row.value(3)
        )
    }

    private static func staticQuery(db: String, sql: String) throws -> Row {
        let output = try sqliteOutput(db: db, sql: sql)
        let columns = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { optionalNumber(String($0).trimmingCharacters(in: .whitespaces)) ?? 0 }
        return Row(columns: columns)
    }

    private static func sqliteOutput(db: String, sql: String) throws -> String {
        try Shell.require("/usr/bin/sqlite3", ["-readonly", db, sql], failureMessage: "Failed to read OpenCode usage database")
    }

    // Read-only query against the OpenCode DB, or nil when the DB is missing/unreadable.
    // Callers outside usage fetching (e.g. agent session lookups) reuse this so the DB
    // path and OPENCODE_DATA_DIR override live in one place.
    static func queryValue(_ sql: String) -> String? {
        let db = databasePath()
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let out = Shell.output("/usr/bin/sqlite3", ["-readonly", db, sql])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    }

    // Unlike queryValue, this keeps "read succeeded, zero rows" (empty string) distinct from
    // "read failed" (throws). The daily-activity scan needs that distinction: an idle install
    // returns no rows and must read as no activity, not as an unreadable provider.
    static func queryText(_ sql: String) throws -> String {
        let db = databasePath()
        guard FileManager.default.fileExists(atPath: db) else {
            throw LocalizedErrorMessage("OpenCode database not found")
        }
        return try sqliteOutput(db: db, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
