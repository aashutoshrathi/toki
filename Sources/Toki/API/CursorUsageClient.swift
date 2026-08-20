import Foundation

enum CursorAuth {
    struct Credentials {
        let token: String
        let userId: String
    }

    static func read(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Credentials? {
        let db = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: db),
              let token = Shell.output("/usr/bin/sqlite3", ["-readonly", db,
                "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let userId = jwtSubject(token) else {
            return nil
        }
        return Credentials(token: token, userId: userId)
    }

    static func jwtSubject(_ token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let data = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = object["sub"] as? String else {
            return nil
        }
        return sub.split(separator: "|").last.map(String.init)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

struct CursorUsageClient {
    struct Usage: Equatable {
        var spentCents: Double
        var hardLimitDollars: Double?
        var inputTokens: Int
        var outputTokens: Int
        var plan: String?
        var cycleEndMs: Double?
    }

    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let activity = CursorLocalActivity.latest()
        guard let credentials = CursorAuth.read() else {
            return localSnapshot(activity: activity)
        }
        let usage = try await fetchUsage(credentials: credentials)
        return usageSnapshot(usage: usage, activity: activity)
    }

    private func usageSnapshot(usage: Usage, activity: Date?) -> AccountSnapshot {
        let spent = usage.spentCents / 100
        var ratio: Double?
        if let limit = usage.hardLimitDollars, limit > 0 {
            ratio = max(0, min(1, 1 - spent / limit))
        }

        var metrics: [MetricLine] = []
        if let plan = usage.plan { metrics.append(MetricLine(label: "Plan", value: plan.capitalized)) }
        if let limit = usage.hardLimitDollars, limit > 0 {
            metrics.append(MetricLine(label: "Spend", value: "\(formatUSD(spent)) / \(formatUSD(limit))"))
        } else {
            metrics.append(MetricLine(label: "Spend", value: formatUSD(spent)))
        }
        if usage.inputTokens > 0 || usage.outputTokens > 0 {
            metrics.append(MetricLine(label: "Tokens",
                value: "\(formatCompact(Double(usage.inputTokens))) in / \(formatCompact(Double(usage.outputTokens))) out"))
        }
        if let end = usage.cycleEndMs {
            metrics.append(MetricLine(label: "Resets", value: relativeDate(Date(timeIntervalSince1970: end / 1000))))
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .cursor,
            primary: ratio.map { "\(Int(($0 * 100).rounded()))% left" } ?? "\(formatUSD(spent)) this cycle",
            subtitle: usage.plan.map { "\($0.capitalized) plan" } ?? "Cursor usage",
            remainingRatio: ratio,
            metrics: metrics,
            isError: false,
            menuBarValue: ratio == nil ? formatUSD(spent) : nil,
            lastActivity: activity
        )
    }

    private func localSnapshot(activity: Date?) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .cursor,
            primary: "No usage API available",
            subtitle: "Sign in to Cursor for usage",
            remainingRatio: nil,
            metrics: [],
            isError: false,
            isAgentDetectionOnly: true,
            lastActivity: activity
        )
    }

    private func fetchUsage(credentials: CursorAuth.Credentials) async throws -> Usage {
        let profile = try await fetchProfile(credentials: credentials)
        var body: [String: Any] = [:]
        if let teamId = profile.teamId { body["teamId"] = teamId }

        let aggregated = try await dashboard("get-aggregated-usage-events", body: body, credentials: credentials)
        var usage = Self.parseAggregated(aggregated)
        usage.plan = profile.plan
        if let configured = account.limit, configured > 0 {
            usage.hardLimitDollars = configured
        } else if let hardLimit = try? await dashboard("get-hard-limit", body: [:], credentials: credentials) {
            usage.hardLimitDollars = Self.parseHardLimit(hardLimit)
        }
        if let teamSpend = try? await dashboard("get-team-spend", body: body, credentials: credentials) {
            usage.cycleEndMs = Self.parseCycleEnd(teamSpend)
        }
        return usage
    }

    static func parseAggregated(_ object: [String: Any]) -> Usage {
        Usage(
            spentCents: doubleFrom(object["totalCostCents"]),
            hardLimitDollars: nil,
            inputTokens: intFrom(object["totalInputTokens"]),
            outputTokens: intFrom(object["totalOutputTokens"]),
            plan: nil,
            cycleEndMs: nil
        )
    }

    static func parseHardLimit(_ object: [String: Any]) -> Double? {
        let limit = doubleFrom(object["hardLimit"])
        return limit > 0 ? limit : nil
    }

    static func parseCycleEnd(_ object: [String: Any]) -> Double? {
        let ms = doubleFrom(object["nextCycleStart"])
        return ms > 0 ? ms : nil
    }

    private func fetchProfile(credentials: CursorAuth.Credentials) async throws -> (plan: String?, teamId: Int?) {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/auth/full_stripe_profile")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["membershipType"] as? String, Self.intFrom(object?["teamId"]).nonZero)
    }

    private func dashboard(_ path: String, body: [String: Any],
                           credentials: CursorAuth.Credentials) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("WorkosCursorSessionToken=\(credentials.userId)::\(credentials.token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode, body: "")
        }
    }

    static func intFrom(_ any: Any?) -> Int {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String, let parsed = Int(value) { return parsed }
        return 0
    }

    static func doubleFrom(_ any: Any?) -> Double {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? String, let parsed = Double(value) { return parsed }
        return 0
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
