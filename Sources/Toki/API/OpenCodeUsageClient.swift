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
        var todayTokens = 0.0
        var weekTokens = 0.0
        var monthTokens = 0.0
        var allTimeTokens = 0.0
        var todayInput = 0
        var todayOutput = 0
        var todayCachedInput = 0
        var todayReasoningOutput = 0
        var sessionCount = 0
    }

    struct UsageRow: Equatable {
        let sessionID: String
        let date: Date?
        let providerID: String?
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
        let cost: Double
    }

    let account: AccountConfig

    func snapshot(db: String? = nil) async throws -> AccountSnapshot {
        let local = try localSnapshot(db: db)
        guard let limits = OpenCodeGoClient.limits() else { return local }
        return OpenCodeUsageClient.merging(limits, into: local)
    }

    private func localSnapshot(db: String? = nil) throws -> AccountSnapshot {
        let dbPath = db ?? OpenCodeUsageClient.databasePath()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            let shortPath = dbPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            throw LocalizedErrorMessage("OpenCode database not found at \(shortPath)")
        }

        let totals = try Self.aggregate(db: dbPath)
        let todayCost = totals.todayCost
        let todayIn = totals.todayInput
        let todayOut = totals.todayOutput
        let totalCost = totals.allTimeCost
        let sessionCount = totals.sessionCount
        var metrics: [MetricLine] = []
        metrics.append(MetricLine(label: "Today", value: "\(formatCompact(Double(todayIn))) in / \(formatCompact(Double(todayOut))) out"))
        metrics.append(MetricLine(label: "Total", value: formatUSD(totalCost)))
        metrics.append(MetricLine(label: "Sessions", value: "\(sessionCount)"))

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .openCode,
            primary: "\(formatUSD(todayCost)) / \(formatCompact(Double(todayIn))) in / \(formatCompact(Double(todayOut))) out today",
            subtitle: "OpenCode - local usage",
            remainingRatio: nil,
            metrics: metrics,
            isError: false,
            menuBarValue: formatUSD(todayCost)
        )
    }

    // Go is a subscription on top of the same local database, so the card keeps today's spend
    // and gains the plan's quota windows. The headline percentage comes from the tightest
    // window: the monthly cap is the plan's size, but a nearly-spent 5-hour window is what
    // stops work first, and the menu bar can only show one number.
    static func merging(_ limits: OpenCodeGoLimits, into snapshot: AccountSnapshot) -> AccountSnapshot {
        var updated = snapshot
        let windows = limits.windowsAsRateLimits
        guard !windows.isEmpty else { return updated }

        var metrics = snapshot.metrics
        var insertAt = metrics.firstIndex { $0.label == "Today" }.map { $0 + 1 } ?? 0
        for (index, window) in windows.enumerated() {
            let source = limits.windows[index]
            var value = "\(source.percentUsed)% used"
            if let hint = window.resetHint { value += " - \(hint)" }
            metrics.insert(MetricLine(label: window.label, value: value), at: insertAt)
            insertAt += 1
            if source.limited {
                metrics.append(MetricLine(label: "Limit", value: "\(window.label) reached"))
            }
        }

        let tightest = windows.min { $0.percentLeft < $1.percentLeft } ?? windows[0]
        let remaining = max(0, min(1, Double(tightest.percentLeft) / 100))
        updated.primary = "\(tightest.percentLeft)% left"
        updated.subtitle = "OpenCode Go - " + (limits.workspaceName ?? "subscription")
        updated.remainingRatio = remaining
        updated.progressRatio = 1 - remaining
        updated.metrics = metrics
        updated.primaryWindow = windows[0]
        updated.secondaryWindow = windows.count > 1 ? windows[1] : nil
        updated.extraWindows = Array(windows.dropFirst(2))
        return updated
    }

    // OpenCode isn't a configured account - if its local database exists we surface it
    // automatically (mirroring how running agents are auto-detected), without writing
    // anything into the user's config file.
    static let autoDetectedID = "opencode-auto"

    static func autoDetectedAccount() -> AccountConfig? {
        guard FileManager.default.fileExists(atPath: databasePath()) else { return nil }
        return AccountConfig(id: autoDetectedID, name: "OpenCode", provider: .openCode)
    }

    static func databasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let override = environment["OPENCODE_DATA_DIR"], !override.isEmpty {
            return (override as NSString).appendingPathComponent("opencode.db")
        }
        return "\(home)/.local/share/opencode/opencode.db"
    }

    // Aggregated cost across all sessions, bucketed by time period. Uses the same
    // calendar boundaries as PiUsageClient.aggregate() so the Analytics tab can sum them.
    static func aggregate(db dbPath: String? = nil, now: Date = Date(), calendar: Calendar = .current) throws -> Totals {
        let db = dbPath ?? databasePath()
        guard FileManager.default.fileExists(atPath: db) else {
            throw LocalizedErrorMessage("OpenCode database not found")
        }

        let day = calendar.dateInterval(of: .day, for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        var totals = Totals()
        var sessions = Set<String>()
        for row in try usageRows(db: db).filter({ $0.providerID != "sarvam" }) {
            sessions.insert(row.sessionID)
            totals.allTimeCost += row.cost
            totals.allTimeTokens += Double(row.total)
            guard let date = row.date else { continue }
            if let day, date >= day.start, date < day.end {
                totals.todayCost += row.cost
                totals.todayInput += row.input
                totals.todayOutput += row.output
                totals.todayCachedInput += row.cacheRead
                totals.todayReasoningOutput += row.reasoning
                totals.todayTokens += Double(row.total)
            }
            if let week, date >= week.start, date < week.end {
                totals.weekCost += row.cost
                totals.weekTokens += Double(row.total)
            }
            if let month, date >= month.start, date < month.end {
                totals.monthCost += row.cost
                totals.monthTokens += Double(row.total)
            }
        }
        totals.sessionCount = sessions.count
        return totals
    }

    static func usageRows(db dbPath: String? = nil) throws -> [UsageRow] {
        let db = dbPath ?? databasePath()
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        let tables = try sqliteOutput(db: db, sql: "SELECT name FROM sqlite_master WHERE type='table';")
            .split(separator: "\n").map(String.init)
        guard tables.contains("session") else { throw LocalizedErrorMessage("Invalid OpenCode usage database") }

        let hasMessage = tables.contains("message")
        var rows: [UsageRow] = []
        if hasMessage {
            let output = try sqliteOutput(db: db, sql: """
            SELECT json_array(session_id, time_created,
                   json_extract(data,'$.providerID'),
                   json_extract(data,'$.tokens.total'), json_extract(data,'$.tokens.input'),
                   json_extract(data,'$.tokens.output'), json_extract(data,'$.tokens.reasoning'),
                   json_extract(data,'$.tokens.cache.read'), json_extract(data,'$.tokens.cache.write'),
                   json_extract(data,'$.cost'))
            FROM message WHERE json_extract(data,'$.role') = 'assistant';
            """)
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let values = try metadataFields(line)
                guard values.count >= 10, !values[0].isEmpty else { continue }
                let input = token(values[4]), output = token(values[5])
                let cacheRead = token(values[7]), cacheWrite = token(values[8])
                rows.append(UsageRow(
                    sessionID: values[0], date: milliseconds(values[1]), providerID: values[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty,
                    input: input, output: output, reasoning: token(values[6]),
                    cacheRead: cacheRead, cacheWrite: cacheWrite,
                    total: total(values[3], input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite),
                    cost: cost(values[9])
                ))
            }
        }

        let columns = Set(try sqliteOutput(db: db, sql: "PRAGMA table_info(session);")
            .split(separator: "\n")
            .compactMap { $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init) })
        guard columns.contains("id"), columns.contains("time_updated") else {
            throw LocalizedErrorMessage("Invalid OpenCode usage database")
        }
        let costColumn = columns.contains("cost") ? "cost" : "0"
        let inputColumn = columns.contains("tokens_input") ? "tokens_input" : "0"
        let outputColumn = columns.contains("tokens_output") ? "tokens_output" : "0"
        let reasoningColumn = columns.contains("tokens_reasoning") ? "tokens_reasoning" : "0"
        let cacheReadColumn = columns.contains("tokens_cache_read") ? "tokens_cache_read" : "0"
        let cacheWriteColumn = columns.contains("tokens_cache_write") ? "tokens_cache_write" : "0"
        let fallback: String
        if hasMessage {
            fallback = """
            SELECT json_array(s.id, s.time_updated, \(costColumn), \(inputColumn), \(outputColumn), \(reasoningColumn), \(cacheReadColumn), \(cacheWriteColumn))
            FROM session s LEFT JOIN (SELECT DISTINCT session_id FROM message WHERE json_extract(data,'$.role') = 'assistant') m
            ON m.session_id = s.id WHERE m.session_id IS NULL;
            """
        } else {
            fallback = "SELECT json_array(id, time_updated, \(costColumn), \(inputColumn), \(outputColumn), \(reasoningColumn), \(cacheReadColumn), \(cacheWriteColumn)) FROM session;"
        }
        for line in try sqliteOutput(db: db, sql: fallback).split(separator: "\n", omittingEmptySubsequences: true) {
            let values = try metadataFields(line)
            guard values.count >= 8, !values[0].isEmpty else { continue }
            let input = token(values[3]), output = token(values[4])
            let cacheRead = token(values[6]), cacheWrite = token(values[7])
            rows.append(UsageRow(
                sessionID: values[0], date: milliseconds(values[1]), providerID: nil,
                input: input, output: output, reasoning: token(values[5]), cacheRead: cacheRead, cacheWrite: cacheWrite,
                total: input + output + cacheRead + cacheWrite, cost: cost(values[2])
            ))
        }
        return rows
    }

    private static func metadataFields(_ line: Substring) throws -> [String] {
        guard let fields = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any] else {
            throw LocalizedErrorMessage("Invalid OpenCode usage row")
        }
        return fields.map { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
    }

    private static func token(_ value: String) -> Int {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return 0 }
        guard number > 0 else { return 0 }
        return Int(exactly: number.rounded(.towardZero)) ?? 0
    }

    private static func total(_ value: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input + output + cacheRead + cacheWrite }
        return token(trimmed)
    }

    private static func cost(_ value: String) -> Double {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return 0 }
        return max(0, number)
    }

    private static func milliseconds(_ value: String) -> Date? {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
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

}
