import Foundation

struct OpenAIUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let key = try SecretResolver.resolve(account: account)
        async let usage = fetchUsage(apiKey: key)
        async let costs = fetchCosts(apiKey: key)
        let (tokenUsage, monthlyCost) = try await (usage, costs)

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

        if let budget = account.monthlyUsdBudget {
            metrics.append(MetricLine(label: "Budget", value: "\(formatUSD(max(budget - monthlyCost, 0))) left"))
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .openai,
            primary: tokenRemaining.map { "\(formatCompact($0)) tokens left" } ?? "\(formatCompact(tokenUsage.totalTokens)) today",
            subtitle: tokenRatio.map { "\(Int(($0 * 100).rounded()))% of daily token budget" } ?? "Usage from organization admin API",
            remainingRatio: tokenRatio,
            metrics: metrics
        )
    }

    private func fetchUsage(apiKey: String) async throws -> TokenUsage {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: "\(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970))"),
            URLQueryItem(name: "end_time", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        let json = try await requestJSON(url: components.url!, headers: ["Authorization": "Bearer \(apiKey)"])
        return TokenUsage.fromOpenAI(json)
    }

    private func fetchCosts(apiKey: String) async throws -> Double {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: "\(Int(Calendar.current.startOfCurrentMonth().timeIntervalSince1970))"),
            URLQueryItem(name: "end_time", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        let json = try await requestJSON(url: components.url!, headers: ["Authorization": "Bearer \(apiKey)"])
        return sumOpenAICosts(json)
    }
}
