import Foundation

// Decode only session metadata and usage events so transcript content never enters Toki's models.
struct SarvamCodeUsageClient {
    struct Totals: Equatable {
        var todayInput = 0
        var todayOutput = 0
        var todayCachedInput = 0
        var todayReasoningOutput = 0
        var todayTokens = 0
        var weekTokens = 0
        var monthTokens = 0
        var allTimeTokens = 0
        var todayCosts = MoneyTotals()
        var weekCosts = MoneyTotals()
        var monthCosts = MoneyTotals()
        var allTimeCosts = MoneyTotals()
        var sessionCount = 0
    }

    struct DayTotal: Equatable {
        var tokens = 0
        var costs = MoneyTotals()
    }

    private struct Entry: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String?
        let id: String?
        let info: TokenInfo?
    }

    private struct TokenInfo: Decodable {
        let totalTokenUsage: TokenUsage?

        private enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
        }
    }

    private struct TokenUsage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    private struct Counters {
        var input = 0
        var cachedInput = 0
        var output = 0
        var reasoningOutput = 0
        var total = 0
        var costs = MoneyTotals()
    }

    private struct Contribution {
        let date: Date?
        let counters: Counters
    }

    private struct FileAggregate {
        let modified: Date?
        let size: Int
        let hasSession: Bool
        let contributions: [Contribution]
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: FileAggregate] = [:]
    }

    private static let cache = Cache()
    private static let maximumRecordBytes = 1024 * 1024
    static let autoDetectedID = "sarvam-code-auto"

    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let totals = try Self.aggregate()
        let todayCost = totals.todayCosts.isEmpty ? formatUSD(0) : totals.todayCosts.formatted
        let totalCost = totals.allTimeCosts.isEmpty ? formatUSD(0) : totals.allTimeCosts.formatted
        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .sarvamCode,
            primary: "\(formatCompact(Double(totals.todayTokens))) tokens today",
            subtitle: "Sarvam Code - local usage",
            remainingRatio: nil,
            metrics: [
                MetricLine(label: "Today", value: "\(formatCompact(Double(totals.todayInput))) in / \(formatCompact(Double(totals.todayOutput))) out"),
                MetricLine(label: "Cached input", value: formatCompact(Double(totals.todayCachedInput))),
                MetricLine(label: "Reasoning output", value: formatCompact(Double(totals.todayReasoningOutput))),
                MetricLine(label: "This week", value: "\(formatCompact(Double(totals.weekTokens))) tokens"),
                MetricLine(label: "This month", value: "\(formatCompact(Double(totals.monthTokens))) tokens"),
                MetricLine(label: "Total", value: "\(formatCompact(Double(totals.allTimeTokens))) tokens"),
                MetricLine(label: "Cost today", value: todayCost),
                MetricLine(label: "Cost total", value: totalCost),
                MetricLine(label: "Sessions", value: "\(totals.sessionCount)")
            ],
            isError: false,
            menuBarValue: todayCost
        )
    }

    static func autoDetectedAccount(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AccountConfig? {
        let root = sarvamHome(environment: environment, home: home)
        let stateExists = FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("state_5.sqlite"))
        let sessionsExist = FileManager.default.fileExists(atPath: sessionRoot(environment: environment, home: home))
        guard stateExists || sessionsExist || UsageFetcher.cliIsInstalled(named: "sarvam-code") else { return nil }
        return AccountConfig(id: autoDetectedID, name: "Sarvam Code", provider: .sarvamCode)
    }

    static func aggregate(
        root: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Totals {
        let resolvedRoot = root ?? sessionRoot(environment: environment, home: home)
        guard FileManager.default.fileExists(atPath: resolvedRoot) else { return Totals() }

        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        var totals = Totals()
        for path in try sessionFiles(root: resolvedRoot) {
            let file = try fileAggregate(path: path)
            guard file.hasSession else { continue }
            totals.sessionCount += 1
            for contribution in file.contributions {
                let counters = contribution.counters
                totals.allTimeTokens += counters.total
                totals.allTimeCosts.add(counters.costs)
                guard let date = contribution.date else { continue }
                if calendar.isDate(date, inSameDayAs: now) {
                    totals.todayInput += counters.input
                    totals.todayOutput += counters.output
                    totals.todayCachedInput += counters.cachedInput
                    totals.todayReasoningOutput += counters.reasoningOutput
                    totals.todayTokens += counters.total
                    totals.todayCosts.add(counters.costs)
                }
                if let week, date >= week.start, date < week.end {
                    totals.weekTokens += counters.total
                    totals.weekCosts.add(counters.costs)
                }
                if let month, date >= month.start, date < month.end {
                    totals.monthTokens += counters.total
                    totals.monthCosts.add(counters.costs)
                }
            }
        }
        return totals
    }

    static func dailyTotals(
        root: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        calendar: Calendar = .current
    ) throws -> [Date: DayTotal] {
        let resolvedRoot = root ?? sessionRoot(environment: environment, home: home)
        guard FileManager.default.fileExists(atPath: resolvedRoot) else { return [:] }
        var totals: [Date: DayTotal] = [:]
        for path in try sessionFiles(root: resolvedRoot) {
            let file = try fileAggregate(path: path)
            guard file.hasSession else { continue }
            for contribution in file.contributions {
                guard let date = contribution.date else { continue }
                let day = calendar.startOfDay(for: date)
                var total = totals[day] ?? DayTotal()
                total.tokens += contribution.counters.total
                total.costs.add(contribution.counters.costs)
                totals[day] = total
            }
        }
        return totals
    }

    static func sarvamHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let override = environment["SARVAM_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            if override == "~" { return home }
            if override.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(override.dropFirst(2))) }
            return (override as NSString).standardizingPath
        }
        return (home as NSString).appendingPathComponent(".sarvam")
    }

    static func sessionRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        (sarvamHome(environment: environment, home: home) as NSString).appendingPathComponent("sessions")
    }

    private static func fileAggregate(path: String) throws -> FileAggregate {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1

        cache.lock.lock()
        if let cached = cache.files[path], cached.size == size, cached.modified == modified {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()

        var hasSession = false
        var previous: Counters?
        var contributions: [Contribution] = []
        try forEachEntry(path: path) { data in
            guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return }
            if entry.type == "session_meta", entry.payload.id != nil {
                hasSession = true
                return
            }
            guard entry.type == "event_msg", entry.payload.type == "token_count",
                  let usage = entry.payload.info?.totalTokenUsage else { return }
            let rawJSON = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let current = Counters(
                input: max(usage.inputTokens ?? 0, 0),
                cachedInput: max(usage.cachedInputTokens ?? 0, 0),
                output: max(usage.outputTokens ?? 0, 0),
                reasoningOutput: max(usage.reasoningOutputTokens ?? 0, 0),
                total: max(usage.totalTokens ?? 0, 0),
                costs: moneyTotals(in: rawJSON)
            )
            let delta = delta(from: previous, to: current)
            previous = current
            guard delta.total > 0 || !delta.costs.isEmpty else { return }
            contributions.append(Contribution(date: entry.timestamp.flatMap(parseTimestamp), counters: delta))
        }

        let aggregate = FileAggregate(modified: modified, size: size, hasSession: hasSession, contributions: contributions)
        cache.lock.lock()
        cache.files[path] = aggregate
        cache.lock.unlock()
        return aggregate
    }

    private static func delta(from previous: Counters?, to current: Counters) -> Counters {
        guard let previous else { return current }
        let reset = current.total < previous.total
        var costs = MoneyTotals()
        for money in current.costs.sortedMoney {
            let amount = reset ? money.amount : max(money.amount - previous.costs.amount(for: money.currencyCode), 0)
            costs.add(Money(amount: amount, currencyCode: money.currencyCode), includingZero: true)
        }
        return Counters(
            input: reset ? current.input : max(current.input - previous.input, 0),
            cachedInput: reset ? current.cachedInput : max(current.cachedInput - previous.cachedInput, 0),
            output: reset ? current.output : max(current.output - previous.output, 0),
            reasoningOutput: reset ? current.reasoningOutput : max(current.reasoningOutput - previous.reasoningOutput, 0),
            total: reset ? current.total : max(current.total - previous.total, 0),
            costs: costs
        )
    }

    // Restrict inference to cost-labelled fields; unrelated amounts are not spend.
    private static func moneyTotals(in value: Any) -> MoneyTotals {
        var totals = MoneyTotals()
        collectMoney(in: value, parentKey: nil, into: &totals)
        return totals
    }

    private static func collectMoney(in value: Any, parentKey: String?, into totals: inout MoneyTotals) {
        if let dict = value as? [String: Any] {
            if let parentKey, parentKey.lowercased().contains("cost") {
                let currency = (dict["currency"] as? String) ?? (dict["currency_code"] as? String) ?? "USD"
                if let amount = optionalNumber(dict["amount"] ?? dict["value"] ?? dict["total"]) {
                    totals.add(Money(amount: amount, currencyCode: currency), includingZero: true)
                    return
                }
            }
            let hasPairedCost = optionalNumber(dict["cost"]) != nil && dict["currency"] is String
            if let amount = optionalNumber(dict["cost"]), let currency = dict["currency"] as? String {
                totals.add(Money(amount: amount, currencyCode: currency), includingZero: true)
            }
            for (key, child) in dict {
                let lower = key.lowercased()
                if lower == "cost", hasPairedCost { continue }
                if lower.contains("cost"), let amount = optionalNumber(child) {
                    let suffix = lower.split(separator: "_").last.map(String.init) ?? ""
                    let currency = suffix.count == 3 && suffix.allSatisfy(\.isLetter) ? suffix : "USD"
                    totals.add(Money(amount: amount, currencyCode: currency), includingZero: true)
                } else {
                    collectMoney(in: child, parentKey: key, into: &totals)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectMoney(in: child, parentKey: parentKey, into: &totals) }
        }
    }

    private static func sessionFiles(root: String) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LocalizedErrorMessage("Unable to read Sarvam Code session history")
        }
        return try enumerator.compactMap { item -> String? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "jsonl" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url.path
        }.sorted()
    }

    private static func forEachEntry(path: String, body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty, line.count <= maximumRecordBytes { body(line) }
            }
            if buffer.count > maximumRecordBytes {
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty, buffer.count <= maximumRecordBytes { body(buffer) }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
