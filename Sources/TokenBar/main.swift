import AppKit
import Foundation
import SwiftUI

private let defaultConfigPath = "~/.tokenbar/config.json"
private let defaultStatePath = "~/.tokenbar/usage-state.json"
private let appUserAgent = "TokenBar/1.0"

enum Provider: String, Codable {
    case openai
    case anthropic
    case chatgpt
    case claude
    case claudeCode
    case manual

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code"
        case .manual: return "Manual"
        }
    }

    var isConsumerTracked: Bool {
        switch self {
        case .chatgpt, .claude, .manual: return true
        case .openai, .anthropic, .claudeCode: return false
        }
    }
}

struct AppConfig: Decodable {
    var refreshMinutes: Int?
    var accountLabels: [AccountLabelConfig]?
    var accounts: [AccountConfig]
}

struct AccountLabelConfig: Decodable {
    var email: String
    var organizationUuid: String?
    var organizationName: String?
    var nickname: String?
    var emoji: String?
    var color: String?
}

struct AccountConfig: Decodable, Identifiable {
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
    var notes: String?
}

struct UsageState: Codable {
    var accounts: [String: AccountUsageState] = [:]
}

struct AccountUsageState: Codable {
    var used: Double
    var lastResetAt: Date?
}

struct MetricLine: Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: String
}

struct AccountSnapshot: Identifiable, Hashable {
    var id: String
    var name: String
    var provider: Provider
    var primary: String
    var subtitle: String
    var remainingRatio: Double?
    var progressRatio: Double? = nil
    var metrics: [MetricLine]
    var accountInfo: [MetricLine] = []
    var isError: Bool = false
    var canAdjust: Bool = false
    var switchTarget: String?
    var emoji: String?
    var colorHex: String?

    static func loading(for account: AccountConfig) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "Refreshing",
            subtitle: account.provider.displayName,
            remainingRatio: nil,
            progressRatio: nil,
            metrics: [],
            isError: false
        )
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [AccountSnapshot] = []
    @Published var lastUpdated: Date?
    @Published var statusText = "Loading"
    @Published var configError: String?

    private var config: AppConfig?
    private var usageState = UsageState()
    private var timer: Timer?

    init() {
        reloadConfig()
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(config?.refreshMinutes ?? 15, 1) * 60)
    }

    func reloadConfig() {
        do {
            config = try ConfigLoader.load()
            usageState = StateLoader.load()
            applyScheduledResets()
            configError = nil
            snapshots = config?.accounts.map(AccountSnapshot.loading) ?? []
            scheduleRefresh()
            refresh()
        } catch {
            config = nil
            configError = error.localizedDescription
            statusText = "Config needed"
            snapshots = [
                AccountSnapshot(
                    id: "config-error",
                    name: "Config needed",
                    provider: .manual,
                    primary: "No config",
                    subtitle: defaultConfigPath,
                    remainingRatio: nil,
                    progressRatio: nil,
                    metrics: [MetricLine(label: "Open README", value: "README.md")],
                    isError: true
                )
            ]
        }
    }

    func refresh() {
        guard let config else { return }
        statusText = "Refreshing"
        snapshots = config.accounts.map(AccountSnapshot.loading)
        let currentState = usageState

        Task {
            let fetched = await UsageFetcher.fetch(config: config, state: currentState)
            snapshots = fetched
            lastUpdated = Date()
            statusText = menuBarStatus(provider: .claudeCode, ratio: fetched.compactMap(\.remainingRatio).min())
        }
    }

    func adjustUsage(accountID: String, delta: Double) {
        guard let account = config?.accounts.first(where: { $0.id == accountID }), account.provider.isConsumerTracked else {
            return
        }
        let current = usageState.accounts[accountID]?.used ?? account.used ?? usageFromRemaining(account)
        let next = max(current + delta, 0)
        usageState.accounts[accountID] = AccountUsageState(
            used: next,
            lastResetAt: usageState.accounts[accountID]?.lastResetAt ?? resetAnchorDate(for: account)
        )
        StateLoader.save(usageState)
        refresh()
    }

    func resetUsage(accountID: String) {
        guard let account = config?.accounts.first(where: { $0.id == accountID }), account.provider.isConsumerTracked else {
            return
        }
        usageState.accounts[accountID] = AccountUsageState(used: 0, lastResetAt: Date())
        StateLoader.save(usageState)
        refresh()
    }

    func switchClaudeAccount(target: String) {
        statusText = "Switching"
        let currentSnapshots = snapshots
        Task {
            let result = await Task.detached {
                Result {
                    try ClaudeSwapRunner.switchTo(target: target)
                }
            }.value

            switch result {
            case .success:
                reloadConfig()
            case .failure(let error):
                statusText = "Switch failed"
                snapshots = currentSnapshots.map { snapshot in
                    guard snapshot.switchTarget == target else { return snapshot }
                    var failed = snapshot
                    failed.isError = true
                    failed.metrics = [MetricLine(label: "Switch", value: error.localizedDescription)] + snapshot.metrics
                    return failed
                }
            }
        }
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func applyScheduledResets() {
        guard let config else { return }
        var changed = false
        for account in config.accounts where account.provider.isConsumerTracked {
            guard let resetEveryHours = account.resetEveryHours, resetEveryHours > 0 else { continue }
            let currentState = usageState.accounts[account.id]
            let anchor = currentState?.lastResetAt ?? resetAnchorDate(for: account) ?? Date()
            let elapsed = Date().timeIntervalSince(anchor)
            let window = resetEveryHours * 3600
            if elapsed >= window {
                let windowsElapsed = floor(elapsed / window)
                let nextAnchor = anchor.addingTimeInterval(windowsElapsed * window)
                usageState.accounts[account.id] = AccountUsageState(used: 0, lastResetAt: nextAnchor)
                changed = true
            }
        }
        if changed {
            StateLoader.save(usageState)
        }
    }
}

enum ConfigLoader {
    static func load() throws -> AppConfig {
        let path = expandedPath(ProcessInfo.processInfo.environment["TOKENBAR_CONFIG"] ?? defaultConfigPath)
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalizedErrorMessage("Missing config at \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        guard !config.accounts.isEmpty else {
            throw LocalizedErrorMessage("Config has no accounts")
        }
        return config
    }
}

enum StateLoader {
    static func load() -> UsageState {
        let path = expandedPath(ProcessInfo.processInfo.environment["TOKENBAR_STATE"] ?? defaultStatePath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder.tokenBar.decode(UsageState.self, from: data) else {
            return UsageState()
        }
        return state
    }

    static func save(_ state: UsageState) {
        let path = expandedPath(ProcessInfo.processInfo.environment["TOKENBAR_STATE"] ?? defaultStatePath)
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.tokenBar.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension JSONDecoder {
    static var tokenBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var tokenBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum UsageFetcher {
    static func fetch(config: AppConfig, state: UsageState) async -> [AccountSnapshot] {
        let accounts = config.accounts
        return await withTaskGroup(of: (Int, [AccountSnapshot]).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    await (index, snapshots(for: account, config: config, state: state))
                }
            }

            var byIndex: [Int: [AccountSnapshot]] = [:]
            for await result in group {
                byIndex[result.0] = result.1
            }
            return accounts.indices.flatMap { byIndex[$0] ?? [] }
        }
    }

    private static func snapshots(for account: AccountConfig, config: AppConfig, state: UsageState) async -> [AccountSnapshot] {
        do {
            switch account.provider {
            case .claudeCode:
                return try await ClaudeCodeUsageClient(account: account, labels: config.accountLabels ?? []).snapshots()
            case .chatgpt, .claude, .manual:
                return [consumerSnapshot(for: account, state: state)]
            case .openai:
                return [try await OpenAIUsageClient(account: account).snapshot()]
            case .anthropic:
                return [try await AnthropicUsageClient(account: account).snapshot()]
            }
        } catch {
            return [AccountSnapshot(
                id: account.id,
                name: account.name,
                provider: account.provider,
                primary: "Unavailable",
                subtitle: error.localizedDescription,
                remainingRatio: nil,
                metrics: account.notes.map { [MetricLine(label: "Note", value: $0)] } ?? [],
                isError: true
            )]
        }
    }

    private static func consumerSnapshot(for account: AccountConfig, state: UsageState) -> AccountSnapshot {
        let label = account.limitLabel ?? "messages"
        let used = state.accounts[account.id]?.used ?? account.used ?? usageFromRemaining(account)
        let limit = account.limit ?? ((account.remaining ?? 0) + used)
        let remaining = account.remaining ?? max(limit - used, 0)
        let ratio = limit > 0 ? max(min(remaining / limit, 1), 0) : nil

        var metrics = [
            MetricLine(label: "Used", value: "\(formatCompact(used)) \(label)"),
            MetricLine(label: "Limit", value: "\(formatCompact(limit)) \(label)")
        ]
        if let resetsAt = account.resetsAt {
            metrics.append(MetricLine(label: "Resets", value: resetsAt))
        }
        if let nextReset = nextResetDate(for: account, state: state.accounts[account.id]) {
            metrics.append(MetricLine(label: "Next reset", value: relativeDate(nextReset)))
        }
        if let notes = account.notes {
            metrics.append(MetricLine(label: "Note", value: notes))
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "\(formatCompact(remaining)) \(label) left",
            subtitle: ratio.map { "\(Int(($0 * 100).rounded()))% remaining" } ?? "Consumer usage ledger",
            remainingRatio: ratio,
            metrics: metrics,
            canAdjust: true
        )
    }
}

struct OpenAIUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let key = try SecretResolver.resolve(account: account)
        async let usage = fetchUsage(apiKey: key)
        async let costs = fetchCosts(apiKey: key)
        let (tokenUsage, monthlyCost) = try await (usage, costs)

        let tokenBudget = account.dailyTokenBudget
        let tokenRemaining = tokenBudget.map { max($0 - tokenUsage.totalTokens, 0) }
        let tokenRatio = tokenBudget.flatMap { $0 > 0 ? tokenRemaining! / $0 : nil }

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
            URLQueryItem(name: "start_time", value: "\(Int(Calendar.current.dateInterval(of: .month, for: Date())!.start.timeIntervalSince1970))"),
            URLQueryItem(name: "end_time", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        let json = try await requestJSON(url: components.url!, headers: ["Authorization": "Bearer \(apiKey)"])
        return sumOpenAICosts(json)
    }
}

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
        let tokenRatio = tokenBudget.flatMap { $0 > 0 ? tokenRemaining! / $0 : nil }

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
            URLQueryItem(name: "starting_at", value: iso8601(Calendar.current.dateInterval(of: .month, for: Date())!.start)),
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

struct ClaudeCodeAccountRecord: Hashable {
    var id: String
    var name: String
    var email: String?
    var organizationName: String?
    var organizationUUID: String?
    var accountNumber: Int?
    var isActive: Bool
    var source: String
    var credentials: String?
    var loadError: String?
    var label: AccountPresentation?
}

struct AccountPresentation: Hashable {
    var nickname: String?
    var emoji: String?
    var color: String?
}

struct ClaudeCodeUsageClient {
    let account: AccountConfig
    let labels: [AccountLabelConfig]

    func snapshots() async throws -> [AccountSnapshot] {
        let records = ClaudeCodeAccountDiscovery.discover(config: account, labels: labels)
        if records.isEmpty {
            return [try await snapshot(for: ClaudeCodeAccountDiscovery.fallbackRecord(config: account, labels: labels))]
        }

        return await withTaskGroup(of: AccountSnapshot.self) { group in
            for record in records {
                group.addTask {
                    await snapshotOrError(for: record)
                }
            }

            var byID: [String: AccountSnapshot] = [:]
            for await snapshot in group {
                byID[snapshot.id] = snapshot
            }
            return records.compactMap { byID[$0.id] }
        }
    }

    private func snapshotOrError(for record: ClaudeCodeAccountRecord) async -> AccountSnapshot {
        do {
            return try await snapshot(for: record)
        } catch {
            return AccountSnapshot(
                id: record.id,
                name: record.label?.nickname ?? record.name,
                provider: .claudeCode,
                primary: "Unavailable",
                subtitle: record.email ?? error.localizedDescription,
                remainingRatio: nil,
                metrics: [MetricLine(label: "Error", value: error.localizedDescription)],
                accountInfo: accountInfoLines(for: record),
                isError: true,
                switchTarget: switchTarget(for: record),
                emoji: record.label?.emoji,
                colorHex: record.label?.color
            )
        }
    }

    private func snapshot(for record: ClaudeCodeAccountRecord) async throws -> AccountSnapshot {
        if let loadError = record.loadError {
            throw LocalizedErrorMessage(loadError)
        }
        guard let credentials = record.credentials, !credentials.isEmpty else {
            throw LocalizedErrorMessage("No credentials found")
        }

        let accessToken = try ClaudeCodeCredentialReader.extractAccessToken(from: credentials)
        let json = try await requestJSON(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "anthropic-beta": "oauth-2025-04-20"
            ]
        )
        let usage = ClaudeCodeUsage(json: json)
        guard usage.hasUsage else {
            throw LocalizedErrorMessage("Claude Code usage unavailable")
        }

        let primaryMetric = usage.primaryMetric ?? UsageMetric(label: "Daily", utilization: usage.worstUtilization ?? 0, resetDescription: nil)
        let usedRatio = max(0, min(1, primaryMetric.utilization / 100))
        let remainingRatio = max(0, min(1, 1 - usedRatio))
        let primary = "\(Int((remainingRatio * 100).rounded()))% left"
        let email = record.email ?? ClaudeCodeCredentialReader.emailIdentifier(from: credentials)

            return AccountSnapshot(
            id: record.id,
            name: record.label?.nickname ?? record.name,
            provider: .claudeCode,
            primary: primary,
            subtitle: email ?? "Claude Code OAuth usage",
            remainingRatio: remainingRatio,
            progressRatio: usedRatio,
            metrics: usage.metrics,
            accountInfo: accountInfoLines(for: record, credentials: credentials),
            switchTarget: switchTarget(for: record),
            emoji: record.label?.emoji,
            colorHex: record.label?.color
        )
    }

    private func switchTarget(for record: ClaudeCodeAccountRecord) -> String? {
        guard !record.isActive else { return nil }
        if let accountNumber = record.accountNumber {
            return "\(accountNumber)"
        }
        return record.email
    }

    private func accountInfoLines(for record: ClaudeCodeAccountRecord, credentials: String? = nil) -> [MetricLine] {
        var lines: [MetricLine] = []
        if let email = record.email ?? credentials.flatMap(ClaudeCodeCredentialReader.emailIdentifier) {
            lines.append(MetricLine(label: "Email", value: email))
        }
        if let organizationName = record.organizationName {
            lines.append(MetricLine(label: "Org", value: organizationName))
        } else if let credentials,
                  let org = ClaudeCodeCredentialReader.organizationName(from: credentials) {
            lines.append(MetricLine(label: "Org", value: org))
        }
        if let organizationUUID = record.organizationUUID {
            lines.append(MetricLine(label: "Org ID", value: compactIdentifier(organizationUUID)))
        }
        return lines
    }
}

enum ClaudeCodeAccountDiscovery {
    private static let backupDir = "~/.claude-swap-backup"

    static func discover(config: AccountConfig, labels: [AccountLabelConfig]) -> [ClaudeCodeAccountRecord] {
        if let sequence = readSequence() {
            return records(from: sequence, labels: labels)
        }
        return [fallbackRecord(config: config, labels: labels)]
    }

    static func fallbackRecord(config: AccountConfig, labels: [AccountLabelConfig]) -> ClaudeCodeAccountRecord {
        do {
            let bundle = try ClaudeCodeCredentialReader.readCredentials(account: config)
            let email = ClaudeCodeCredentialReader.emailIdentifier(from: bundle.credentials)
            let orgName = ClaudeCodeCredentialReader.organizationName(from: bundle.credentials)
            let orgUUID = ClaudeCodeCredentialReader.organizationUUID(from: bundle.credentials)
            return ClaudeCodeAccountRecord(
                id: config.id,
                name: config.name,
                email: email,
                organizationName: orgName,
                organizationUUID: orgUUID,
                accountNumber: nil,
                isActive: true,
                source: bundle.source,
                credentials: bundle.credentials,
                loadError: nil,
                label: resolveLabel(email: email, organizationName: orgName, organizationUUID: orgUUID, labels: labels)
            )
        } catch {
            return ClaudeCodeAccountRecord(
                id: config.id,
                name: config.name,
                email: nil,
                organizationName: nil,
                organizationUUID: nil,
                accountNumber: nil,
                isActive: true,
                source: "Claude Code Keychain",
                credentials: nil,
                loadError: error.localizedDescription,
                label: nil
            )
        }
    }

    private static func records(from sequence: ClaudeSwapSequence, labels: [AccountLabelConfig]) -> [ClaudeCodeAccountRecord] {
        let orderedNumbers = sequence.sequence ?? sequence.accounts.keys.compactMap(Int.init).sorted()
        return orderedNumbers.compactMap { number in
            guard let metadata = sequence.accounts["\(number)"] else { return nil }
            let active = sequence.activeAccountNumber == number
            let credentialResult = credentials(for: number, metadata: metadata, active: active)
            return ClaudeCodeAccountRecord(
                id: "claude-\(number)-\(metadata.email)",
                name: metadata.email,
                email: metadata.email,
                organizationName: metadata.organizationName,
                organizationUUID: metadata.organizationUuid,
                accountNumber: number,
                isActive: active,
                source: credentialResult.source,
                credentials: credentialResult.credentials,
                loadError: credentialResult.error,
                label: resolveLabel(
                    email: metadata.email,
                    organizationName: metadata.organizationName,
                    organizationUUID: metadata.organizationUuid,
                    labels: labels
                )
            )
        }
    }

    private static func resolveLabel(email: String?, organizationName: String?, organizationUUID: String?, labels: [AccountLabelConfig]) -> AccountPresentation? {
        guard let email else { return nil }
        let normalizedEmail = email.lowercased()
        let matches = labels.filter { $0.email.lowercased() == normalizedEmail }
        let match = matches.first(where: { label in
            label.organizationUuid != nil && label.organizationUuid == organizationUUID
        }) ?? matches.first(where: { label in
            label.organizationName != nil && label.organizationName == organizationName
        }) ?? matches.first(where: { label in
            label.organizationUuid == nil && label.organizationName == nil
        })

        guard let match else { return nil }
        return AccountPresentation(nickname: match.nickname, emoji: match.emoji, color: match.color)
    }

    private static func credentials(for number: Int, metadata: ClaudeSwapAccount, active: Bool) -> (credentials: String?, source: String, error: String?) {
        if active {
            do {
                let activeBundle = try ClaudeCodeCredentialReader.readMacOSKeychainCredentials()
                return (activeBundle.credentials, "\(activeBundle.source) active", nil)
            } catch {
                return (nil, "Claude Code Keychain active", error.localizedDescription)
            }
        }

        let keychainAccount = "account-\(number)-\(metadata.email)"
        do {
            let credentials = try ClaudeCodeCredentialReader.readKeychain(service: "claude-swap", account: keychainAccount)
            return (credentials, "claude-swap \(number)", nil)
        } catch {
            return (nil, "claude-swap \(number)", error.localizedDescription)
        }
    }

    private static func readSequence() -> ClaudeSwapSequence? {
        let path = expandedPath("\(backupDir)/sequence.json")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder.tokenBar.decode(ClaudeSwapSequence.self, from: data)
    }
}

struct ClaudeSwapSequence: Decodable {
    var activeAccountNumber: Int?
    var sequence: [Int]?
    var accounts: [String: ClaudeSwapAccount]
}

struct ClaudeSwapAccount: Decodable {
    var email: String
    var uuid: String?
    var organizationUuid: String?
    var organizationName: String?
    var added: String?
}

enum ClaudeCodeCredentialReader {
    struct CredentialBundle {
        var credentials: String
        var source: String
    }

    static func readCredentials(account: AccountConfig) throws -> CredentialBundle {
        if let apiKey = account.apiKey, !apiKey.isEmpty {
            return CredentialBundle(credentials: apiKey, source: "Config")
        }
        if let envName = account.apiKeyEnv,
           let value = ProcessInfo.processInfo.environment[envName],
           !value.isEmpty {
            return CredentialBundle(credentials: value, source: "Env \(envName)")
        }
        if let command = account.apiKeyCommand, !command.isEmpty {
            let credentials = try SecretResolver.runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
            return CredentialBundle(credentials: credentials, source: "Command")
        }
        return try readMacOSKeychainCredentials()
    }

    static func extractAccessToken(from credentials: String) throws -> String {
        guard let data = credentials.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw LocalizedErrorMessage("No Claude Code OAuth access token found")
        }
        return token
    }

    static func emailIdentifier(from credentials: String) -> String? {
        guard let json = credentialJSON(credentials) else { return nil }
        return TokenBar.emailIdentifier(in: json)
    }

    static func organizationName(from credentials: String) -> String? {
        guard let json = credentialJSON(credentials) else { return nil }
        return firstString(in: json, keys: ["organizationName", "organization_name", "orgName", "workspaceName"])
    }

    static func organizationUUID(from credentials: String) -> String? {
        guard let json = credentialJSON(credentials) else { return nil }
        return firstString(in: json, keys: ["organizationUuid", "organizationId", "organization_id"])
    }

    static func accountInfo(from credentials: String, source: String) -> [MetricLine] {
        var lines = [MetricLine(label: "Source", value: source)]

        guard let data = credentials.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return lines
        }

        if let email = TokenBar.emailIdentifier(in: json) {
            lines.append(MetricLine(label: "Email", value: email))
        } else if let account = firstString(in: json, keys: ["accountEmail", "account_email", "login", "username", "preferred_username"]) {
            lines.append(MetricLine(label: "Account", value: account))
        }
        if let org = firstString(in: json, keys: ["organizationName", "organization_name", "orgName", "workspaceName"]) {
            lines.append(MetricLine(label: "Org", value: org))
        }
        if let id = firstString(in: json, keys: ["organizationUuid", "organizationId", "organization_id", "accountUuid", "accountId"]) {
            lines.append(MetricLine(label: "ID", value: compactIdentifier(id)))
        }
        if let scope = firstString(in: json, keys: ["scope", "scopes"]) {
            lines.append(MetricLine(label: "Scope", value: scope))
        }

        return lines
    }

    static func readMacOSKeychainCredentials() throws -> CredentialBundle {
        #if os(macOS)
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let credentials = try readKeychain(service: "Claude Code-credentials", account: user)
        return CredentialBundle(credentials: credentials, source: "Keychain \(user)")
        #else
        throw LocalizedErrorMessage("Claude Code Keychain lookup is macOS-only")
        #endif
    }

    static func readKeychain(service: String, account: String) throws -> String {
        #if os(macOS)
        let command = "security find-generic-password -s '\(shellEscaped(service))' -a '\(shellEscaped(account))' -w"
        let credentials = try SecretResolver.runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credentials.isEmpty else {
            throw LocalizedErrorMessage("Keychain item is empty")
        }
        return credentials
        #else
        throw LocalizedErrorMessage("Keychain lookup is macOS-only")
        #endif
    }

    private static func credentialJSON(_ credentials: String) -> [String: Any]? {
        guard let data = credentials.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

struct UsageMetric {
    var label: String
    var utilization: Double
    var resetDescription: String?
}

struct ClaudeCodeUsage {
    var primaryMetric: UsageMetric?
    var metrics: [MetricLine] = []
    var worstUtilization: Double?

    var hasUsage: Bool {
        !metrics.isEmpty
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }

        if let fiveHour = data["five_hour"] as? [String: Any] {
            setPrimaryWindow("Daily", fiveHour)
        }
        if let sevenDay = data["seven_day"] as? [String: Any] {
            appendWindow("7d", sevenDay)
        }
        if let extraUsage = data["extra_usage"] as? [String: Any],
           (extraUsage["is_enabled"] as? Bool) == true {
            appendSpend(extraUsage)
        }
    }

    private mutating func setPrimaryWindow(_ label: String, _ window: [String: Any]) {
        let utilization = numericValue(window["utilization"] ?? 0)
        worstUtilization = max(worstUtilization ?? utilization, utilization)
        primaryMetric = UsageMetric(
            label: label,
            utilization: utilization,
            resetDescription: resetDescription(window["resets_at"])
        )
        metrics.append(MetricLine(label: label, value: "\(Int(utilization.rounded()))% used"))
        if let reset = primaryMetric?.resetDescription {
            metrics.append(MetricLine(label: "Reset", value: reset))
        }
    }

    private mutating func appendWindow(_ label: String, _ window: [String: Any]) {
        let utilization = numericValue(window["utilization"] ?? 0)
        worstUtilization = max(worstUtilization ?? utilization, utilization)

        var value = "\(Int(utilization.rounded()))% used"
        if let reset = resetDescription(window["resets_at"]) {
            value += " - resets \(reset)"
        }
        metrics.append(MetricLine(label: label, value: value))
    }

    private mutating func appendSpend(_ extraUsage: [String: Any]) {
        guard let usedCents = optionalNumber(extraUsage["used_credits"]),
              let limitCents = optionalNumber(extraUsage["monthly_limit"]),
              let utilization = optionalNumber(extraUsage["utilization"]) else {
            return
        }

        var value = "\(formatUSD(usedCents / 100)) / \(formatUSD(limitCents / 100))"
        value += " - \(Int(utilization.rounded()))%"
        if let reset = resetDescription(extraUsage["resets_at"]) {
            value += " - resets \(reset)"
        }
        metrics.append(MetricLine(label: "Spend", value: value))
    }
}

struct TokenUsage {
    var inputTokens: Double
    var outputTokens: Double
    var totalTokens: Double { inputTokens + outputTokens }

    static func fromOpenAI(_ json: Any) -> TokenUsage {
        let input = sumNumbers(in: json, keys: [
            "input_tokens",
            "input_audio_tokens"
        ])
        let output = sumNumbers(in: json, keys: [
            "output_tokens",
            "output_audio_tokens"
        ])
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    static func fromAnthropic(_ json: Any) -> TokenUsage {
        let detailedInput = sumNumbers(in: json, keys: [
            "uncached_input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens"
        ])
        let input = detailedInput > 0 ? detailedInput : sumNumbers(in: json, keys: ["input_tokens"])
        let output = sumNumbers(in: json, keys: ["output_tokens"])
        return TokenUsage(inputTokens: input, outputTokens: output)
    }
}

enum ClaudeSwapRunner {
    static func switchTo(target: String) throws {
        let path = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let command = "PATH=\"\(path)\" claude-swap --switch-to '\(shellEscaped(target))'"
        _ = try SecretResolver.runShell(command)
    }
}

enum SecretResolver {
    static func resolve(account: AccountConfig) throws -> String {
        if let apiKey = account.apiKey, !apiKey.isEmpty {
            return apiKey
        }
        if let envName = account.apiKeyEnv, let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
            return value
        }
        if let command = account.apiKeyCommand, !command.isEmpty {
            let value = try runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        throw LocalizedErrorMessage("No API key configured for \(account.name)")
    }

    static func runShell(_ command: String) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalizedErrorMessage(message.isEmpty ? "Command failed: \(command)" : message)
        }
        return output
    }
}

func requestJSON(url: URL, headers: [String: String]) async throws -> Any {
    var request = URLRequest(url: url)
    request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw LocalizedErrorMessage("HTTP \(http.statusCode): \(body.prefix(140))")
    }
    return try JSONSerialization.jsonObject(with: data)
}

func sumNumbers(in value: Any, keys: Set<String>) -> Double {
    if let dict = value as? [String: Any] {
        return dict.reduce(0) { total, pair in
            let current = keys.contains(pair.key) ? numericValue(pair.value) : 0
            return total + current + sumNumbers(in: pair.value, keys: keys)
        }
    }
    if let array = value as? [Any] {
        return array.reduce(0) { $0 + sumNumbers(in: $1, keys: keys) }
    }
    return 0
}

func maxNumber(in value: Any, keys: Set<String>) -> Double {
    if let dict = value as? [String: Any] {
        return dict.reduce(0) { currentMax, pair in
            let current = keys.contains(pair.key) ? numericValue(pair.value) : 0
            return max(currentMax, current, maxNumber(in: pair.value, keys: keys))
        }
    }
    if let array = value as? [Any] {
        return array.reduce(0) { max($0, maxNumber(in: $1, keys: keys)) }
    }
    return 0
}

func sumOpenAICosts(_ value: Any) -> Double {
    if let dict = value as? [String: Any] {
        var total = 0.0
        if let amount = dict["amount"] as? [String: Any] {
            total += numericValue(amount["value"] ?? 0)
        }
        for child in dict.values {
            total += sumOpenAICosts(child)
        }
        return total
    }
    if let array = value as? [Any] {
        return array.reduce(0) { $0 + sumOpenAICosts($1) }
    }
    return 0
}

func sumAnthropicCosts(_ value: Any) -> Double {
    let cents = sumNumbers(in: value, keys: ["amount_cents", "cost_cents"])
    if cents > 0 { return cents / 100 }
    return sumNumbers(in: value, keys: ["cost_usd", "amount_usd", "cost"])
}

func numericValue(_ value: Any) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) ?? 0 }
    return 0
}

func optionalNumber(_ value: Any?) -> Double? {
    guard let value else { return nil }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

func resetDescription(_ value: Any?) -> String? {
    guard let raw = value as? String,
          let resetDate = ISO8601DateFormatter().date(from: raw) else {
        return nil
    }
    let countdown = relativeDate(resetDate)
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDateInToday(resetDate) ? "HH:mm" : "MMM d HH:mm"
    return "\(formatter.string(from: resetDate)) (\(countdown))"
}

func shellEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

func firstString(in value: Any, keys: Set<String>) -> String? {
    if let dict = value as? [String: Any] {
        for key in keys {
            if let direct = dict[key] as? String, !direct.isEmpty {
                return direct
            }
            if let array = dict[key] as? [String], !array.isEmpty {
                return array.joined(separator: ", ")
            }
        }
        for child in dict.values {
            if let found = firstString(in: child, keys: keys) {
                return found
            }
        }
    }
    if let array = value as? [Any] {
        for child in array {
            if let found = firstString(in: child, keys: keys) {
                return found
            }
        }
    }
    return nil
}

func emailIdentifier(in json: [String: Any]) -> String? {
    if let email = firstString(in: json, keys: ["email", "accountEmail", "account_email"]),
       email.contains("@") {
        return email
    }

    if let username = firstString(in: json, keys: ["preferred_username", "username", "login"]),
       username.contains("@") {
        return username
    }

    for tokenKey in ["accessToken", "idToken", "identityToken"] {
        guard let token = firstString(in: json, keys: [tokenKey]),
              let claims = jwtPayload(token) else {
            continue
        }
        if let email = firstString(in: claims, keys: ["email", "preferred_username", "username", "upn"]),
           email.contains("@") {
            return email
        }
    }

    return nil
}

func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - payload.count % 4) % 4
    payload += String(repeating: "=", count: padding)
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

func compactIdentifier(_ value: String) -> String {
    guard value.count > 16 else { return value }
    return "\(value.prefix(8))...\(value.suffix(6))"
}

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func expandedPath(_ rawPath: String) -> String {
    if rawPath == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
    if rawPath.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(rawPath.dropFirst(2)))
            .path
    }
    return rawPath
}

func usageFromRemaining(_ account: AccountConfig) -> Double {
    max((account.limit ?? 0) - (account.remaining ?? 0), 0)
}

func resetAnchorDate(for account: AccountConfig) -> Date? {
    guard let resetAnchor = account.resetAnchor else { return nil }
    return ISO8601DateFormatter().date(from: resetAnchor)
}

func nextResetDate(for account: AccountConfig, state: AccountUsageState?) -> Date? {
    guard let resetEveryHours = account.resetEveryHours, resetEveryHours > 0 else { return nil }
    let window = resetEveryHours * 3600
    let anchor = state?.lastResetAt ?? resetAnchorDate(for: account) ?? Date()
    let elapsed = max(Date().timeIntervalSince(anchor), 0)
    let windowsElapsed = floor(elapsed / window) + 1
    return anchor.addingTimeInterval(windowsElapsed * window)
}

func formatCompact(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = value >= 100 ? 0 : 1

    let absValue = abs(value)
    if absValue >= 1_000_000 {
        return "\(formatter.string(from: NSNumber(value: value / 1_000_000)) ?? "0")M"
    }
    if absValue >= 1_000 {
        return "\(formatter.string(from: NSNumber(value: value / 1_000)) ?? "0")K"
    }
    return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
}

func formatUSD(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = value >= 10 ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0"
}

struct LocalizedErrorMessage: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let configError = store.configError {
                Text(configError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.snapshots) { snapshot in
                        AccountCard(snapshot: snapshot, store: store)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: accountListHeight())
            footer
        }
        .padding(16)
        .frame(width: popoverWidth(), height: popoverHeight(), alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenBar")
                    .font(.system(size: 22, weight: .semibold))
                Text(store.lastUpdated.map { "Updated \(relativeDate($0))" } ?? "Clean quota glance")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                store.reloadConfig()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .font(.system(size: 12, weight: .medium))
    }
}

struct AccountCard: View {
    var snapshot: AccountSnapshot
    @ObservedObject var store: UsageStore
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)

                        AccountBadge(snapshot: snapshot)

                        Text(accountIdentifier)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 12)

                        Text(collapsedStatus)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(snapshot.isError ? .red : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse account" : "Show account details")

                if let switchTarget = snapshot.switchTarget {
                    Button {
                        store.switchClaudeAccount(target: switchTarget)
                    } label: {
                        Text("Switch")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Switch Claude Code to this account")
                }
            }

            if isExpanded {
                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.provider.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(snapshot.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(snapshot.isError ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(snapshot.primary)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.isError ? .red : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let ratio = snapshot.progressRatio ?? snapshot.remainingRatio.map({ 1 - $0 }) {
                    ProgressView(value: ratio)
                        .tint(progressTint(ratio))
                }

                if !snapshot.metrics.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(snapshot.metrics) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                }

                if !snapshot.accountInfo.isEmpty {
                    Divider()
                    VStack(spacing: 5) {
                        ForEach(snapshot.accountInfo) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                }

                if snapshot.canAdjust {
                    HStack(spacing: 8) {
                        Button {
                            store.adjustUsage(accountID: snapshot.id, delta: -1)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .help("Subtract one")

                        Button {
                            store.adjustUsage(accountID: snapshot.id, delta: 1)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add one")

                        Spacer()

                        Button("Reset") {
                            store.resetUsage(accountID: snapshot.id)
                        }
                        .help("Reset usage for this account")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var accountIdentifier: String {
        if let email = snapshot.accountInfo.first(where: { $0.label == "Email" })?.value {
            return email
        }
        if snapshot.subtitle.contains("@") {
            return snapshot.subtitle
        }
        return snapshot.name
    }

    private var collapsedStatus: String {
        snapshot.isError ? "Not connected" : snapshot.primary
    }

    private func progressTint(_ ratio: Double) -> Color {
        if ratio >= 0.85 { return .red }
        if ratio >= 0.60 { return .orange }
        return .green
    }
}

struct MetricRow: View {
    var metric: MetricLine
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(metric.value)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(metric.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                    .lineLimit(1)
                Text(copied ? "Copied" : metric.value)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help("Copy \(metric.label)")
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct ProviderLogo: View {
    var provider: Provider
    var size: CGFloat

    var body: some View {
        Group {
            switch provider {
            case .claude, .claudeCode, .anthropic:
                ClaudeLogoMark()
                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
            case .openai, .chatgpt:
                OpenAILogoMark()
                    .foregroundStyle(Color.primary)
            case .manual:
                Circle()
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

struct AccountBadge: View {
    var snapshot: AccountSnapshot
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let emoji = snapshot.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: size * 0.9))
            } else {
                ZStack {
                    if let color = colorFromHex(snapshot.colorHex) {
                        Circle()
                            .fill(color.opacity(0.18))
                            .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 1))
                    }
                    ProviderLogo(provider: snapshot.provider, size: size * 0.72)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct ClaudeLogoMark: View {
    var body: some View {
        ClaudeLogoShape().fill()
    }
}

struct ClaudeLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let rawPath = "M52.4285 162.873L98.7844 136.879L99.5485 134.602L98.7844 133.334H96.4921L88.7237 132.862L62.2346 132.153L39.3113 131.207L17.0249 130.026L11.4214 128.844L6.2 121.873L6.7094 118.447L11.4214 115.257L18.171 115.847L33.0711 116.911L55.485 118.447L71.6586 119.392L95.728 121.873H99.5485L100.058 120.337L98.7844 119.392L97.7656 118.447L74.5877 102.732L49.4995 86.1905L36.3823 76.62L29.3779 71.7757L25.8121 67.2858L24.2839 57.3608L30.6515 50.2716L39.3113 50.8623L41.4763 51.4531L50.2636 58.1879L68.9842 72.7209L93.4357 90.6804L97.0015 93.6343L98.4374 92.6652L98.6571 91.9801L97.0015 89.2625L83.757 65.2772L69.621 40.8192L63.2534 30.6579L61.5978 24.632C60.9565 22.1032 60.579 20.0111 60.579 17.4246L67.8381 7.49965L71.9133 6.19995L81.7193 7.49965L85.7946 11.0443L91.9074 24.9865L101.714 46.8451L116.996 76.62L121.453 85.4816L123.873 93.6343L124.764 96.1155H126.292V94.6976L127.566 77.9197L129.858 57.3608L132.15 30.8942L132.915 23.4505L136.608 14.4708L143.994 9.62643L149.725 12.344L154.437 19.0788L153.8 23.4505L150.998 41.6463L145.522 70.1215L141.957 89.2625H143.994L146.414 86.7813L156.093 74.0206L172.266 53.698L179.398 45.6635L187.803 36.802L193.152 32.5484H203.34L210.726 43.6549L207.415 55.1159L196.972 68.3492L188.312 79.5739L175.896 96.2095L168.191 109.585L168.882 110.689L170.738 110.53L198.755 104.504L213.91 101.787L231.994 98.7149L240.144 102.496L241.036 106.395L237.852 114.311L218.495 119.037L195.826 123.645L162.07 131.592L161.696 131.893L162.137 132.547L177.36 133.925L183.855 134.279H199.774L229.447 136.524L237.215 141.605L241.8 147.867L241.036 152.711L229.065 158.737L213.019 154.956L175.45 145.977L162.587 142.787H160.805V143.85L171.502 154.366L191.242 172.089L215.82 195.011L217.094 200.682L213.91 205.172L210.599 204.699L188.949 188.394L180.544 181.069L161.696 165.118H160.422V166.772L164.752 173.152L187.803 207.771L188.949 218.405L187.294 221.832L181.308 223.959L174.813 222.777L161.187 203.754L147.305 182.486L136.098 163.345L134.745 164.2L128.075 235.42L125.019 239.082L117.887 241.8L111.902 237.31L108.718 229.984L111.902 215.452L115.722 196.547L118.779 181.541L121.58 162.873L123.291 156.636L123.14 156.219L121.773 156.449L107.699 175.752L86.304 204.699L69.3663 222.777L65.291 224.431L58.2867 220.768L58.9235 214.27L62.8713 208.48L86.304 178.705L100.44 160.155L109.551 149.507L109.462 147.967L108.959 147.924L46.6977 188.512L35.6182 189.93L30.7788 185.44L31.4156 178.115L33.7079 175.752L52.4285 162.873Z"
        return svgPath(rawPath, in: rect, viewBox: CGSize(width: 248, height: 248))
    }
}

struct OpenAILogoMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .stroke(lineWidth: 1.7)
                    .frame(width: 9.5, height: 5.5)
                    .offset(x: 3.6)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
    }
}

func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

func colorFromHex(_ raw: String?) -> Color? {
    guard var raw else { return nil }
    raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") {
        raw.removeFirst()
    }
    guard raw.count == 6, let value = Int(raw, radix: 16) else {
        return nil
    }
    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255
    return Color(red: red, green: green, blue: blue)
}

func svgPath(_ raw: String, in rect: CGRect, viewBox: CGSize) -> Path {
    let tokens = raw.replacingOccurrences(of: "Z", with: " Z ")
        .replacingOccurrences(of: "M", with: " M ")
        .replacingOccurrences(of: "L", with: " L ")
        .replacingOccurrences(of: "H", with: " H ")
        .replacingOccurrences(of: "V", with: " V ")
        .replacingOccurrences(of: "C", with: " C ")
        .split { $0.isWhitespace || $0 == "," }
        .map(String.init)

    var path = Path()
    var index = 0
    var command = ""
    var current = CGPoint.zero
    let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
    let xOffset = rect.midX - viewBox.width * scale / 2
    let yOffset = rect.midY - viewBox.height * scale / 2

    func mapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: xOffset + point.x * scale, y: yOffset + point.y * scale)
    }

    func nextNumber() -> CGFloat? {
        guard index < tokens.count, let number = Double(tokens[index]) else { return nil }
        index += 1
        return CGFloat(number)
    }

    while index < tokens.count {
        if Double(tokens[index]) == nil {
            command = tokens[index]
            index += 1
        }

        switch command {
        case "M":
            guard let x = nextNumber(), let y = nextNumber() else { return path }
            current = CGPoint(x: x, y: y)
            path.move(to: mapped(current))
            command = "L"
        case "L":
            guard let x = nextNumber(), let y = nextNumber() else { return path }
            current = CGPoint(x: x, y: y)
            path.addLine(to: mapped(current))
        case "H":
            guard let x = nextNumber() else { return path }
            current = CGPoint(x: x, y: current.y)
            path.addLine(to: mapped(current))
        case "V":
            guard let y = nextNumber() else { return path }
            current = CGPoint(x: current.x, y: y)
            path.addLine(to: mapped(current))
        case "C":
            guard let x1 = nextNumber(), let y1 = nextNumber(),
                  let x2 = nextNumber(), let y2 = nextNumber(),
                  let x = nextNumber(), let y = nextNumber() else { return path }
            let end = CGPoint(x: x, y: y)
            path.addCurve(to: mapped(end), control1: mapped(CGPoint(x: x1, y: y1)), control2: mapped(CGPoint(x: x2, y: y2)))
            current = end
        case "Z":
            path.closeSubpath()
        default:
            index += 1
        }
    }

    return path
}

func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func popoverWidth() -> CGFloat {
    min(390, max(340, (NSScreen.main?.visibleFrame.width ?? 390) - 32))
}

func popoverHeight() -> CGFloat {
    min(620, max(360, (NSScreen.main?.visibleFrame.height ?? 620) - 96))
}

func accountListHeight() -> CGFloat {
    max(220, popoverHeight() - 118)
}

func menuBarStatus(provider: Provider, ratio: Double?) -> String {
    let mark: String
    switch provider {
    case .claudeCode, .claude:
        mark = "✳︎"
    case .openai, .chatgpt:
        mark = "○"
    case .anthropic:
        mark = "✳︎"
    case .manual:
        mark = "•"
    }

    guard let ratio else {
        return "\(mark) --"
    }
    return "\(mark) \(Int((ratio * 100).rounded()))%"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = menuBarStatus(provider: .claudeCode, ratio: nil)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth(), height: popoverHeight())
        popover.contentViewController = NSHostingController(rootView: MenuContentView(store: store))
        popover.delegate = self

        Task { @MainActor in
            for await text in store.$statusText.values {
                statusItem.button?.title = text
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
