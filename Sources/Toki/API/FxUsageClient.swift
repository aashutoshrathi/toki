import Foundation

// fx (Vercel) records per-generation token/cost facts in a single local JSONL ledger
// (~/.fx/usage.jsonl). Spend is aggregated locally, matching OpenCode/Pi; the AI Gateway
// credit balance comes from `fx credits --json`, which is the one figure the ledger can't
// supply because it is account-wide rather than recorded per machine.
struct FxUsageClient {
    struct Totals: Equatable {
        var todayInput = 0.0
        var todayOutput = 0.0
        var todayCacheRead = 0.0
        var todayCost = 0.0
        var weekCost = 0.0
        var monthCost = 0.0
        var allTimeCost = 0.0
        var requestCount = 0
        var lastActivityMs = 0.0
    }

    private struct Entry: Decodable {
        let kind: String
        let fact: Fact?
    }

    private struct Fact: Decodable {
        let id: String?
        let createdAtMs: Double?
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheReadTokens: Double?
        let cacheWriteTokens: Double?
        let totalCost: Double?
    }

    private struct Credits: Decodable {
        let balance: String?
    }

    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let totals = try Self.aggregate()
        let balance = Self.creditBalance()

        var metrics: [MetricLine] = []
        if let balance {
            metrics.append(MetricLine(label: "Credits", value: balance))
        }
        metrics.append(contentsOf: [
            MetricLine(label: "Today", value: "\(formatCompact(totals.todayInput)) in / \(formatCompact(totals.todayOutput)) out"),
            MetricLine(label: "This week", value: formatUSD(totals.weekCost)),
            MetricLine(label: "This month", value: formatUSD(totals.monthCost)),
            MetricLine(label: "Total", value: formatUSD(totals.allTimeCost)),
            MetricLine(label: "Requests", value: "\(totals.requestCount)")
        ])

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .fx,
            primary: "\(formatUSD(totals.todayCost)) / \(formatCompact(totals.todayInput)) in / \(formatCompact(totals.todayOutput)) out today",
            subtitle: balance.map { "AI Gateway credits: \($0)" } ?? "fx - local usage",
            remainingRatio: nil,
            metrics: metrics,
            isError: false,
            menuBarValue: formatUSD(totals.todayCost),
            lastActivity: totals.lastActivityMs > 0 ? Date(timeIntervalSince1970: totals.lastActivityMs / 1000) : nil
        )
    }

    static let autoDetectedID = "fx-auto"

    static func autoDetectedAccount(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> AccountConfig? {
        guard FileManager.default.fileExists(atPath: ledgerPath(home: home)) else { return nil }
        return AccountConfig(id: autoDetectedID, name: "fx", provider: .fx)
    }

    static func ledgerPath(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        (home as NSString).appendingPathComponent(".fx/usage.jsonl")
    }

    static func aggregate(path: String? = nil,
                          home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                          now: Date = Date(),
                          calendar: Calendar = .current) throws -> Totals {
        let ledger = path ?? ledgerPath(home: home)
        guard FileManager.default.fileExists(atPath: ledger) else {
            throw LocalizedErrorMessage("fx usage ledger not found")
        }

        var totals = Totals()
        var seen: Set<String> = []
        let startOfDay = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return totals }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let month = calendar.dateInterval(of: .month, for: now)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        try forEachLine(path: ledger) { line in
            guard let entry = try? decoder.decode(Entry.self, from: line),
                  entry.kind == "generation", let fact = entry.fact else { return }
            if let id = fact.id, !seen.insert(id).inserted { return }

            let cost = number(fact.totalCost)
            totals.allTimeCost += cost
            totals.requestCount += 1

            guard let createdAtMs = fact.createdAtMs, createdAtMs > 0 else { return }
            if createdAtMs > totals.lastActivityMs { totals.lastActivityMs = createdAtMs }
            let date = Date(timeIntervalSince1970: createdAtMs / 1000)
            if date >= startOfDay, date < nextDay {
                totals.todayInput += number(fact.inputTokens)
                totals.todayOutput += number(fact.outputTokens)
                totals.todayCacheRead += number(fact.cacheReadTokens)
                totals.todayCost += cost
            }
            if let week, date >= week.start, date < week.end { totals.weekCost += cost }
            if let month, date >= month.start, date < month.end { totals.monthCost += cost }
        }
        return totals
    }

    // The AI Gateway balance is account-wide, so it lives behind `fx credits`, not the local
    // ledger. Best-effort: nil when fx is unresolved, the call fails, or the payload is unexpected.
    static func creditBalance() -> String? {
        guard let binary = fxBinary(),
              let output = Shell.output(binary, ["credits", "--json"]),
              let data = output.data(using: .utf8),
              let credits = try? JSONDecoder().decode(Credits.self, from: data),
              let balance = credits.balance?.trimmingCharacters(in: .whitespacesAndNewlines),
              !balance.isEmpty else {
            return nil
        }
        return balance
    }

    private static func fxBinary() -> String? {
        ["~/.local/bin/fx", "/usr/local/bin/fx", "/opt/homebrew/bin/fx"]
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func forEachLine(path: String, _ body: (Data) -> Void) throws {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var record = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for byte in chunk {
                    if byte == 0x0A {
                        if !record.isEmpty { body(record) }
                        record.removeAll(keepingCapacity: true)
                    } else {
                        record.append(byte)
                    }
                }
            }
            if !record.isEmpty { body(record) }
        } catch { throw LocalizedErrorMessage("Unable to read the fx usage ledger") }
    }

    private static func number(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }
}
