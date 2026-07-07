import Foundation

struct UsageState: Codable {
    var accounts: [String: AccountUsageState] = [:]
    var apiLastCalledAt: [String: Date] = [:]

    enum CodingKeys: String, CodingKey {
        case accounts
        case apiLastCalledAt
    }

    init(accounts: [String: AccountUsageState] = [:], apiLastCalledAt: [String: Date] = [:]) {
        self.accounts = accounts
        self.apiLastCalledAt = apiLastCalledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([String: AccountUsageState].self, forKey: .accounts) ?? [:]
        apiLastCalledAt = try container.decodeIfPresent([String: Date].self, forKey: .apiLastCalledAt) ?? [:]
    }
}

struct AccountUsageState: Codable {
    var used: Double
    var lastResetAt: Date?
}
