import Foundation

struct OpenAIUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let key = try SecretResolver.resolve(account: account)
        async let usage = fetchUsage(apiKey: key)
        async let costs = fetchCosts(apiKey: key)
        let (tokenUsage, monthlyCosts) = try await (usage, costs)

        return account.tokenBudgetSnapshot(
            provider: .openai,
            usage: tokenUsage,
            monthlyCosts: monthlyCosts,
            subtitleFallback: "Usage from organization admin API"
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

    private func fetchCosts(apiKey: String) async throws -> MoneyTotals {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: "\(Int(Calendar.current.startOfCurrentMonth().timeIntervalSince1970))"),
            URLQueryItem(name: "end_time", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        let json = try await requestJSON(url: components.url!, headers: ["Authorization": "Bearer \(apiKey)"])
        return sumOpenAICostsByCurrency(json)
    }
}
