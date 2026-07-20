import Foundation

/// One provider's measured work on one calendar day.
struct DailyActivity: Hashable, Sendable {
    let day: Date
    let provider: Provider
    let tokens: Int
    let cost: Double
}

// Rebuilds daily activity from each tool's own session store rather than from Toki's recorded
// quota samples.
//
// The heatmap originally derived usage from UsageHistoryEntry, which only exists for days Toki
// itself was running and recording. That made the chart empty for any period before the app was
// installed, and destroyable by anything that resets local state - the history really was lost
// that way once. The tools' own session files are the durable record: they predate Toki, survive
// its state being cleared, and cover cost-based providers that have no quota percentage to
// sample, which is what kept OpenCode and Pi out of the chart.
enum DailyActivityScanner {
    static func scan(dayCount: Int, now: Date = Date(), calendar: Calendar = .current) async -> [DailyActivity] {
        await Task.detached(priority: .utility) {
            let earliest = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now))
                ?? calendar.startOfDay(for: now)
            var results: [DailyActivity] = []
            results.append(contentsOf: claudeActivity(since: earliest, calendar: calendar))
            results.append(contentsOf: openCodeActivity(since: earliest, calendar: calendar))
            results.append(contentsOf: piActivity(since: earliest, calendar: calendar))
            return results
        }.value
    }

    // MARK: - Claude Code

    // Walks ~/.claude/projects/<encoded-cwd>/*.jsonl, summing each assistant message's usage
    // into the day of its timestamp. Cost is priced from the recorded model, so a session that
    // switched models is billed at each model's own rate.
    private static func claudeActivity(since earliest: Date, calendar: Calendar) -> [DailyActivity] {
        let root = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/projects"
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }

        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        for project in projects {
            let directory = "\(root)/\(project)"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = "\(directory)/\(file)"
                // Skip whole files last written before the window - the cheapest possible filter
                // on what is otherwise a lot of JSON parsing.
                if let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                   modified < earliest {
                    continue
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
                accumulateClaude(data: data, since: earliest, calendar: calendar, into: &byDay)
            }
        }
        return byDay.map { DailyActivity(day: $0.key, provider: .claudeCode, tokens: $0.value.tokens, cost: $0.value.cost) }
    }

    // Extracted for testing.
    static func accumulateClaude(
        data: Data,
        since earliest: Date,
        calendar: Calendar,
        into byDay: inout [Date: (tokens: Int, cost: Double)]
    ) {
        for lineBytes in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let timestamp = (json["timestamp"] as? String).flatMap(parseISO8601),
                  timestamp >= earliest,
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

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

    // Grouped in SQL rather than in Swift: the database already indexes the timestamp, and this
    // avoids pulling every session row across the process boundary just to bucket it.
    private static func openCodeActivity(since earliest: Date, calendar: Calendar) -> [DailyActivity] {
        let cutoff = Int(earliest.timeIntervalSince1970 * 1000)
        let query = """
        SELECT strftime('%Y-%m-%d', time_updated/1000, 'unixepoch', 'localtime') AS day, \
        SUM(COALESCE(cost,0)), SUM(COALESCE(tokens_input,0) + COALESCE(tokens_output,0)) \
        FROM session WHERE time_updated >= \(cutoff) GROUP BY day;
        """
        guard let raw = OpenCodeUsageClient.queryValue(query), !raw.isEmpty else { return [] }

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

    private static func piActivity(since earliest: Date, calendar: Calendar) -> [DailyActivity] {
        guard let totals = try? PiUsageClient.dailyTotals(calendar: calendar) else { return [] }
        return totals
            .filter { $0.key >= earliest }
            .map { DailyActivity(day: $0.key, provider: .pi, tokens: $0.value.tokens, cost: $0.value.cost) }
    }

    // MARK: - Parsing

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
