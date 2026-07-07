import Foundation

struct AnthropicUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let key = try SecretResolver.resolve(account: account)
        async let usage = fetchUsage(apiKey: key)
        async let costs = fetchCosts(apiKey: key)
        async let rateLimits = fetchRateLimits(apiKey: key)
        let (tokenUsage, monthlyCost, tokenLimitPerMinute) = try await (usage, costs, rateLimits)

        let tokenBudget = account.dailyTokenBudget
        let tokenRemaining = tokenBudget.map { max($0 - tokenUsage.totalTokens, 0) }
        let tokenRatio: Double?
        if let tokenBudget, tokenBudget > 0, let tokenRemaining {
            tokenRatio = tokenRemaining / tokenBudget
        } else {
            tokenRatio = nil
        }

        var metrics = [
            MetricLine(label: "Today", value: "\(formatCompact(tokenUsage.totalTokens)) tokens"),
            MetricLine(label: "Input", value: formatCompact(tokenUsage.inputTokens)),
            MetricLine(label: "Output", value: formatCompact(tokenUsage.outputTokens)),
            MetricLine(label: "Month", value: formatUSD(monthlyCost))
        ]

        if tokenLimitPerMinute > 0 {
            metrics.append(MetricLine(label: "Rate limit", value: "\(formatCompact(tokenLimitPerMinute)) tok/min"))
        }
        if let budget = account.monthlyUsdBudget {
            metrics.append(MetricLine(label: "Budget", value: "\(formatUSD(max(budget - monthlyCost, 0))) left"))
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .anthropic,
            primary: tokenRemaining.map { "\(formatCompact($0)) tokens left" } ?? "\(formatCompact(tokenUsage.totalTokens)) today",
            subtitle: tokenRatio.map { "\(Int(($0 * 100).rounded()))% of daily token budget" } ?? "Usage from Anthropic Admin API",
            remainingRatio: tokenRatio,
            metrics: metrics
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

    private func fetchCosts(apiKey: String) async throws -> Double {
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso8601(Calendar.current.startOfCurrentMonth())),
            URLQueryItem(name: "ending_at", value: iso8601(Date()))
        ]
        let json = try await requestJSON(url: components.url!, headers: anthropicHeaders(apiKey))
        return sumAnthropicCosts(json)
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
