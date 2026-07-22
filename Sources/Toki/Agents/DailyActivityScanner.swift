import Foundation

/// One provider's measured work on one calendar day.
struct DailyActivity: Hashable, Sendable {
    let day: Date
    let provider: Provider
    let tokens: Int
    let cost: Double
}

// Daily activity from each tool's own session store, not from Toki's recorded quota samples.
// Session files predate Toki's install, survive its state being cleared, and cover cost-based
// providers that have no quota percentage to sample.
enum DailyActivityScanner {
    /// Read failures are reported separately from an absence of work; a bare array conflated
    /// them and made a failed read render as "no activity".
    struct Outcome: Sendable {
        var activities: [DailyActivity] = []
        /// Providers whose history could not be read at all. Empty is the healthy case.
        var unreadable: [Provider] = []

        var isCompleteFailure: Bool { activities.isEmpty && !unreadable.isEmpty }
    }

    static func scan(dayCount: Int, now: Date = Date(), calendar: Calendar = .current) async -> Outcome {
        await Task.detached(priority: .utility) {
            let earliest = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now))
                ?? calendar.startOfDay(for: now)
            var outcome = Outcome()
            for (provider, activity) in [
                (Provider.claudeCode, claudeActivity(since: earliest, calendar: calendar)),
                (Provider.openCode, openCodeActivity(since: earliest, calendar: calendar)),
                (Provider.pi, piActivity(since: earliest, calendar: calendar)),
            ] {
                guard let activity else {
                    outcome.unreadable.append(provider)
                    DiagnosticLogger.shared.record(
                        .warning, component: "activity", code: "provider_unreadable",
                        detail: provider.displayName
                    )
                    continue
                }
                outcome.activities.append(contentsOf: activity)
            }
            return outcome
        }.value
    }

    // MARK: - Claude Code

    // Priced from each message's own model, so a mid-session model switch bills correctly.
    /// nil means the store could not be read; an empty array means it was read and held nothing.
    private static func claudeActivity(since earliest: Date, calendar: Calendar) -> [DailyActivity]? {
        let root = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/projects"
        // A missing directory is a legitimate "Claude Code was never used here", not a failure.
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }

        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        // Scan-wide: a resumed conversation repeats messages across session files.
        var seen: Set<String> = []
        for project in projects {
            let directory = "\(root)/\(project)"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = "\(directory)/\(file)"
                // Cheapest filter available before a lot of JSON parsing.
                if let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                   modified < earliest {
                    continue
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
                accumulateClaude(data: data, since: earliest, calendar: calendar, seen: &seen, into: &byDay)
            }
        }
        return byDay.map { DailyActivity(day: $0.key, provider: .claudeCode, tokens: $0.value.tokens, cost: $0.value.cost) }
    }

    // Extracted for testing.
    static func accumulateClaude(
        data: Data,
        since earliest: Date,
        calendar: Calendar,
        seen: inout Set<String>,
        into byDay: inout [Date: (tokens: Int, cost: Double)]
    ) {
        for lineBytes in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let timestamp = (json["timestamp"] as? String).flatMap(parseISO8601),
                  timestamp >= earliest,
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            // One turn is written as several lines, one per content block, each repeating the
            // same id and the same cumulative usage. Counting every line inflated totals ~78%.
            if let identity = Self.messageIdentity(json: json, message: message) {
                guard seen.insert(identity).inserted else { continue }
            }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0

            let day = calendar.startOfDay(for: timestamp)
            var entry = byDay[day] ?? (0, 0)
            entry.tokens += input + output + cacheWrite + cacheRead
            if let model = message["model"] as? String,
               let cost = ModelPricing.costUSD(
                   model: model,
                   inputTokens: input,
                   outputTokens: output,
                   cacheWriteTokens: cacheWrite,
                   cacheReadTokens: cacheRead
               ) {
                entry.cost += cost
            }
            byDay[day] = entry
        }
    }

    // MARK: - OpenCode

    // Grouped in SQL: the timestamp is indexed, and this avoids moving every row.
    private static func openCodeActivity(since earliest: Date, calendar: Calendar) -> [DailyActivity]? {
        let cutoff = Int(earliest.timeIntervalSince1970 * 1000)
        let query = """
        SELECT strftime('%Y-%m-%d', time_updated/1000, 'unixepoch', 'localtime') AS day, \
        SUM(COALESCE(cost,0)), SUM(COALESCE(tokens_input,0) + COALESCE(tokens_output,0)) \
        FROM session WHERE time_updated >= \(cutoff) GROUP BY day;
        """
        // No database at all is "not installed"; a database that refuses to answer is a failure;
        // a database that answers with no rows is an idle install. queryText keeps the last two
        // apart - queryValue would collapse the zero-row case into the failure case.
        guard FileManager.default.fileExists(atPath: OpenCodeUsageClient.databasePath()) else { return [] }
        let raw: String
        do {
            raw = try OpenCodeUsageClient.queryText(query)
        } catch {
            return nil
        }
        guard !raw.isEmpty else { return [] }

        return raw.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3,
                  let day = parseDay(columns[0], calendar: calendar) else { return nil }
            return DailyActivity(
                day: day,
                provider: .openCode,
                tokens: Int(Double(columns[2]) ?? 0),
                cost: Double(columns[1]) ?? 0
            )
        }
    }

    // MARK: - Pi

    private static func piActivity(since earliest: Date, calendar: Calendar) -> [DailyActivity]? {
        // Pi reports "no session history" by throwing, which is absence rather than failure.
        guard (try? PiUsageClient.sessionRoot()) != nil else { return [] }
        guard let totals = try? PiUsageClient.dailyTotals(calendar: calendar) else { return nil }
        return totals
            .filter { $0.key >= earliest }
            .map { DailyActivity(day: $0.key, provider: .pi, tokens: $0.value.tokens, cost: $0.value.cost) }
    }

    // MARK: - Parsing

    /// nil when neither id is present, in which case the caller counts the line: under-counting
    /// is the worse error.
    static func messageIdentity(json: [String: Any], message: [String: Any]) -> String? {
        let messageID = message["id"] as? String
        let requestID = json["requestId"] as? String
        guard messageID != nil || requestID != nil else { return nil }
        return "\(messageID ?? "")\u{1F}\(requestID ?? "")"
    }

    private static func parseDay(_ value: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
