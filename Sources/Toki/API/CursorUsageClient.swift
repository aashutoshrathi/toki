import CoreFoundation
import Foundation

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

    func snapshot(previous: AccountSnapshot? = nil, login: CursorAuth.Login? = nil) async throws -> AccountSnapshot {
        let activity = CursorLocalActivity.latest()
        let login = login ?? CursorAuth.read()
        let credentials: CursorAuth.Credentials
        switch login {
        case .missing:
            return localSnapshot(activity: activity)
        case .connected(let login):
            credentials = login
        }
        let previous = Self.verifiedPrevious(previous, login: login)
        do {
            let status: [String: Any]?
            var probeFailure: Error?
            do {
                status = try await dashboard("dashboard/get-sand-usage-status", body: [:], credentials: credentials)
            } catch {
                try Task.checkCancellation()
                let code = (error as? HTTPStatusError)?.statusCode
                if var last = previous, last.primaryWindow != nil,
                   code != 401, code != 403 {
                    last.lastActivity = activity
                    return last
                }
                if code == 429 { throw error }
                probeFailure = error
                status = nil
            }
            if let shared = status, shared["isUnified"] as? Bool == true {
                guard let weekly = Self.parseUnifiedUsage(shared) else {
                    return localSnapshot(activity: activity, detail: "Cursor did not report a current weekly allowance")
                }
                let email = await fetchEmail(credentials: credentials)
                try Task.checkCancellation()
                let quota = email.map { WeeklySubscriptionQuota(email: $0, ratio: weekly.ratio, window: weekly.window) }
                return AccountSnapshot(
                    id: account.id, name: account.name, provider: .cursor,
                    primary: "\(weekly.ratio.formatted(.percent.precision(.fractionLength(0...2)))) left",
                    subtitle: "X Subscription · shared with Grok",
                    remainingRatio: weekly.ratio, metrics: [],
                    accountInfo: emailAccountInfo(email) + [MetricLine(label: "Plan", value: "X Subscription")],
                    primaryWindow: weekly.window, lastActivity: activity, weeklySubscriptionQuota: quota,
                    cursorIdentity: credentials.userId
                )
            }
            async let email = fetchEmail(credentials: credentials)
            let usage = try await fetchUsage(credentials: credentials, probeFailure: probeFailure,
                                            knownLegacy: previous != nil && previous?.primaryWindow == nil)
            var snapshot = usageSnapshot(usage: usage, activity: activity)
            snapshot.accountInfo = emailAccountInfo(await email)
            try Task.checkCancellation()
            snapshot.cursorIdentity = credentials.userId
            return snapshot
        } catch let error as HTTPStatusError where error.statusCode == 401 || error.statusCode == 403 {
            return localSnapshot(activity: activity)
        } catch where isConnectivityFailure(error) || (error as? HTTPStatusError)?.statusCode == 429 {
            guard var last = previous else { throw error }
            last.lastActivity = activity
            return last
        }
    }

    static func verifiedPrevious(_ snapshot: AccountSnapshot?, login: CursorAuth.Login, now: Date = Date()) -> AccountSnapshot? {
        guard let snapshot, snapshot.provider == .cursor, !snapshot.isError, !snapshot.isAgentDetectionOnly,
              case .connected(let credentials) = login, snapshot.cursorIdentity == credentials.userId,
              snapshot.primaryWindow?.resetAt.map({ $0 > now }) ?? true else { return nil }
        return snapshot
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

    private func localSnapshot(activity: Date?, detail: String = "Local activity") -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .cursor,
            primary: "Cursor usage unavailable",
            subtitle: detail,
            remainingRatio: nil,
            metrics: [],
            isError: false,
            isAgentDetectionOnly: true,
            lastActivity: activity
        )
    }

    static func parseUnifiedUsage(_ object: [String: Any], now: Date = Date()) -> (ratio: Double, window: RateLimitWindow)? {
        let hasLimit = (object["includedLimitZero"] as? Bool).map { !$0 }
            ?? object["hasNonZeroIncludedLimit"] as? Bool
        guard object["isUnified"] as? Bool == true, hasLimit == true,
              (object["usagePercent"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) ?? true,
              let used = optionalNumber(object["usagePercent"]), used.isFinite, used >= 0,
              let reset = resetDate(object["nextResetTimestampUtc"]), reset > now else { return nil }

        let ratio = max(0, 1 - used / 100)
        return (ratio, RateLimitWindow(
            label: "7d", percentLeft: Int((ratio * 100).rounded()),
            resetHint: "resets in \(resetDescription(for: reset))", resetAt: reset, duration: 7 * 86_400
        ))
    }

    private func fetchUsage(credentials: CursorAuth.Credentials, probeFailure: Error?, knownLegacy: Bool) async throws -> Usage {
        let profile = try await fetchProfile(credentials: credentials)
        // During a dashboard outage, only show classic spend for an identified legacy plan.
        if let probeFailure, !knownLegacy, !Self.isLegacyMembership(profile.plan) { throw probeFailure }
        var body: [String: Any] = [:]
        if let teamId = profile.teamId { body["teamId"] = teamId }

        let aggregated = try await dashboard("dashboard/get-aggregated-usage-events", body: body, credentials: credentials)
        var usage = Self.parseAggregated(aggregated)
        usage.plan = profile.plan
        if let configured = account.limit, configured > 0 {
            usage.hardLimitDollars = configured
        } else if let hardLimit = try? await dashboard("dashboard/get-hard-limit", body: [:], credentials: credentials) {
            usage.hardLimitDollars = Self.parseHardLimit(hardLimit)
        }
        if let teamSpend = try? await dashboard("dashboard/get-team-spend", body: body, credentials: credentials) {
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

    private func fetchEmail(credentials: CursorAuth.Credentials) async -> String? {
        let identity = try? await dashboard("auth/me", credentials: credentials)
        return identity.flatMap { firstString(in: $0, keys: ["email"]) }
    }

    private func fetchProfile(credentials: CursorAuth.Credentials) async throws -> (plan: String?, teamId: Int?) {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/auth/full_stripe_profile")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let data = try await Self.send(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["membershipType"] as? String, Self.intFrom(object?["teamId"]).nonZero)
    }

    private func dashboard(_ path: String, body: [String: Any]? = nil,
                           credentials: CursorAuth.Credentials) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/\(path)")!)
        request.timeoutInterval = 15
        request.setValue("WorkosCursorSessionToken=\(credentials.userId)::\(credentials.token)", forHTTPHeaderField: "Cookie")
        if let body {
            request.httpMethod = "POST"
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data = try await Self.send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalizedErrorMessage("Cursor returned an invalid dashboard response")
        }
        return object
    }

    static func isLegacyMembership(_ plan: String?) -> Bool {
        switch plan?.lowercased() {
        case "hobby", "pro", "pro_plus", "pro+", "business", "team", "teams", "enterprise": true
        default: false
        }
    }

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let sameOrigin = response.url?.scheme == request.url?.scheme
                && response.url?.host == request.url?.host
                && response.url?.port == request.url?.port
            completionHandler(sameOrigin ? request : nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()

    private static func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try checkStatus(response)
            return data
        } catch {
            recordAPIFailure(request.url, method: request.httpMethod ?? "GET", error: error)
            throw error
        }
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
