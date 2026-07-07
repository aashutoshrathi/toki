import Foundation

struct AppConfig: Codable {
    var refreshMinutes: Int?
    var accountLabels: [AccountLabelConfig]?
    var accounts: [AccountConfig]
}

struct AccountLabelConfig: Codable {
    var email: String
    var organizationUuid: String?
    var organizationName: String?
    var nickname: String?
    var emoji: String?
    var color: String?
}

struct AccountConfig: Codable, Identifiable {
    var id: String
    var name: String
    var provider: Provider
    var apiKey: String?
    var apiKeyEnv: String?
    var apiKeyCommand: String?
    var dailyTokenBudget: Double?
    var monthlyUsdBudget: Double?
    var limitLabel: String?
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var resetsAt: String?
    var resetEveryHours: Double?
    var resetAnchor: String?
    var claudeSwapCommand: String?
    var codexAuthPath: String?
    var notes: String?
}
