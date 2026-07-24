import Foundation

extension AccountConfig {
    // The Anthropic and OpenAI admin APIs return the same shape — a day's token usage plus a
    // month-to-date cost — and turn it into an identical card. This builds that card once:
    // the daily-budget ratio, the Today/Input/Output/Month metrics, an optional monthly-budget
    // line, and the primary/subtitle text. Providers pass their own `extraMetrics` (e.g. a rate
    // limit), which land after Month and before Budget, and a `subtitleFallback` for when no
    // daily budget is configured.
    func tokenBudgetSnapshot(
        provider: Provider,
        usage: TokenUsage,
        monthlyCost: Double,
        subtitleFallback: String,
        extraMetrics: [MetricLine] = []
    ) -> AccountSnapshot {
        let tokenRemaining = dailyTokenBudget.map { max($0 - usage.totalTokens, 0) }
        let tokenRatio: Double?
        if let dailyTokenBudget, dailyTokenBudget > 0, let tokenRemaining {
            tokenRatio = tokenRemaining / dailyTokenBudget
        } else {
            tokenRatio = nil
        }

        var metrics = [
            MetricLine(label: "Today", value: "\(formatCompact(usage.totalTokens)) tokens"),
            MetricLine(label: "Input", value: formatCompact(usage.inputTokens)),
            MetricLine(label: "Output", value: formatCompact(usage.outputTokens)),
            MetricLine(label: "Month", value: formatUSD(monthlyCost))
        ]
        metrics.append(contentsOf: extraMetrics)
        if let monthlyUsdBudget {
            metrics.append(MetricLine(label: "Budget", value: "\(formatUSD(max(monthlyUsdBudget - monthlyCost, 0))) left"))
        }

        return AccountSnapshot(
            id: id,
            name: name,
            provider: provider,
            primary: tokenRemaining.map { "\(formatCompact($0)) tokens left" } ?? "\(formatCompact(usage.totalTokens)) today",
            subtitle: tokenRatio.map { "\(Int(($0 * 100).rounded()))% of daily token budget" } ?? subtitleFallback,
            remainingRatio: tokenRatio,
            metrics: metrics
        )
    }
}
