import Foundation

struct AnthropicUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let key = try SecretResolver.resolve(account: account)
        async let usage = fetchUsage(apiKey: key)
        async let costs = fetchCosts(apiKey: key)
        async let rateLimits = fetchRateLimits(apiKey: key)
        let (tokenUsage, monthlyCosts, tokenLimitPerMinute) = try await (usage, costs, rateLimits)

        var extraMetrics: [MetricLine] = []
        if tokenLimitPerMinute > 0 {
            extraMetrics.append(MetricLine(label: "Rate limit", value: "\(formatCompact(tokenLimitPerMinute)) tok/min"))
        }

        return account.tokenBudgetSnapshot(
            provider: .anthropic,
            usage: tokenUsage,
            monthlyCosts: monthlyCosts,
            subtitleFallback: "Usage from Anthropic Admin API",
            extraMetrics: extraMetrics
        )
    }

    private func fetchUsage(apiKey: String) async throws -> TokenUsage {
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso8601(Calendar.current.startOfDay(for: Date()))),
            URLQueryItem(name: "ending_at", value: iso8601(Date())),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        let json = try await requestJSON(url: components.url!, headers: anthropicHeaders(apiKey))
        return TokenUsage.fromAnthropic(json)
    }

    private func fetchCosts(apiKey: String) async throws -> MoneyTotals {
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso8601(Calendar.current.startOfCurrentMonth())),
            URLQueryItem(name: "ending_at", value: iso8601(Date()))
        ]
        let json = try await requestJSON(url: components.url!, headers: anthropicHeaders(apiKey))
        var totals = MoneyTotals()
        totals.add(.usd(sumAnthropicCosts(json)), includingZero: true)
        return totals
    }

    private func fetchRateLimits(apiKey: String) async throws -> Double {
        let json = try await requestJSON(
            url: URL(string: "https://api.anthropic.com/v1/organizations/rate_limits")!,
            headers: anthropicHeaders(apiKey)
        )
        return maxNumber(in: json, keys: ["input_tokens_per_minute", "output_tokens_per_minute"])
    }

    private func anthropicHeaders(_ apiKey: String) -> [String: String] {
        [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01"
        ]
    }
}
