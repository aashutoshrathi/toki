import AppKit
import Foundation
import SwiftUI

private let defaultConfigPath = "~/.toki/config.json"
private let defaultStatePath = "~/.toki/usage-state.json"
private let legacyConfigPath = "~/.tokenbar/config.json"
private let legacyStatePath = "~/.tokenbar/usage-state.json"
private let appVersion = "2.0.2"
private let appUserAgent = "Toki/\(appVersion)"
private var debugLogHandler: ((String) -> Void)?

private extension Calendar {
    func startOfCurrentMonth() -> Date {
        dateInterval(of: .month, for: Date())?.start ?? startOfDay(for: Date())
    }
}

enum Provider: String, Codable {
    case openai
    case codex
    case anthropic
    case chatgpt
    case claude
    case claudeCode
    case manual

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .codex: return "Codex"
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
        case .openai, .codex, .anthropic, .claudeCode: return false
        }
    }

    var isClaudeAccount: Bool {
        self == .claudeCode || self == .claude
    }
}

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
    var switchCommand: String?
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
    @Published var debugMode = false
    @Published var debugLog: [DebugLogEntry] = []

    private var config: AppConfig?
    private var usageState = UsageState()
    private var timer: Timer?
    private var isRefreshing = false

    init() {
        reloadConfig()
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(config?.refreshMinutes ?? 5, 1) * 60)
    }

    func reloadConfig() {
        do {
            config = try ConfigLoader.load()
            usageState = StateLoader.load()
            applyScheduledResets()
            configError = nil
            snapshots = config?.accounts.map(AccountSnapshot.loading) ?? []
            scheduleRefresh()
            refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
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

    func refresh(keepsExistingSnapshots: Bool = true, minimumRefreshInterval: TimeInterval? = nil) {
        guard let config, !isRefreshing else {
            if isRefreshing { logDebug("Refresh skipped - already in progress") }
            return
        }
        isRefreshing = true
        statusText = "Refreshing"
        logDebug("Refresh started")
        if !keepsExistingSnapshots || snapshots.isEmpty {
            snapshots = config.accounts.map(AccountSnapshot.loading)
        }
        let currentState = usageState
        let previousSnapshots = snapshots

        Task {
            defer { isRefreshing = false }
            let response = await UsageFetcher.fetch(
                config: config,
                state: currentState,
                previousSnapshots: previousSnapshots,
                minimumRefreshInterval: minimumRefreshInterval
            )
            for key in response.apiCallKeys {
                usageState.apiLastCalledAt[key] = response.fetchedAt
            }
            if !response.apiCallKeys.isEmpty {
                StateLoader.save(usageState)
            }
            let sorted = sortedByAvailability(response.snapshots)
            let errorCount = sorted.filter(\.isError).count
            logDebug("Refresh complete: \(sorted.count) accounts (\(errorCount) errors)")
            for snapshot in sorted where snapshot.isError {
                logDebug("  [\(snapshot.id)] \(snapshot.name): \(snapshot.subtitle)")
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                snapshots = sorted
            }
            lastUpdated = Date()
            statusText = menuBarStatus(for: sorted)
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

    func renameAccount(snapshot: AccountSnapshot, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var config else { return }

        if snapshot.provider.isClaudeAccount,
           let email = emailAddress(in: snapshot) {
            var labels = config.accountLabels ?? []
            if let index = labels.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                labels[index].nickname = trimmed
            } else {
                labels.append(AccountLabelConfig(
                    email: email,
                    organizationUuid: nil,
                    organizationName: organizationName(in: snapshot),
                    nickname: trimmed,
                    emoji: nil,
                    color: nil
                ))
            }
            config.accountLabels = labels
        } else if let index = config.accounts.firstIndex(where: { $0.id == snapshot.id }) {
            config.accounts[index].name = trimmed
        } else {
            return
        }

        do {
            try ConfigLoader.save(config)
            self.config = config
            snapshots = snapshots.map { current in
                guard current.id == snapshot.id else { return current }
                var updated = current
                updated.name = trimmed
                return updated
            }
        } catch {
            configError = "Could not save alias: \(error.localizedDescription)"
        }
    }

    func switchClaudeAccount(target: String, command: String?) {
        statusText = "Switching"
        let currentSnapshots = snapshots
        Task {
            let result = await Task.detached {
                Result {
                    try ClaudeSwapRunner.switchTo(target: target, command: command)
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
            Task { @MainActor in self?.refresh(keepsExistingSnapshots: true) }
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

    func logDebug(_ message: String) {
        guard debugMode else { return }
        debugLog.append(DebugLogEntry(timestamp: Date(), message: message))
        if debugLog.count > 100 {
            debugLog.removeFirst(debugLog.count - 100)
        }
    }

    func toggleDebug() {
        debugMode.toggle()
        if debugMode {
            debugLogHandler = { [weak self] in self?.logDebug($0) }
            logDebug("Debug mode enabled")
        } else {
            debugLogHandler = nil
        }
    }
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

enum ConfigLoader {
    static var path: String {
        if let path = ProcessInfo.processInfo.environment["TOKI_CONFIG"], !path.isEmpty {
            return expandedPath(path)
        }
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_CONFIG"], !path.isEmpty {
            return expandedPath(path)
        }

        let preferred = expandedPath(defaultConfigPath)
        let legacy = expandedPath(legacyConfigPath)
        if !FileManager.default.fileExists(atPath: preferred),
           FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return preferred
    }

    static func load() throws -> AppConfig {
        let path = Self.path
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

    static func save(_ config: AppConfig) throws {
        let url = URL(fileURLWithPath: path)
        let data = try JSONEncoder.toki.encode(config)
        try data.write(to: url, options: .atomic)
    }

    static func openInDefaultEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

enum StateLoader {
    static var path: String {
        if let path = ProcessInfo.processInfo.environment["TOKI_STATE"], !path.isEmpty {
            return expandedPath(path)
        }
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_STATE"], !path.isEmpty {
            return expandedPath(path)
        }

        let preferred = expandedPath(defaultStatePath)
        let legacy = expandedPath(legacyStatePath)
        if !FileManager.default.fileExists(atPath: preferred),
           FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return preferred
    }

    static func load() -> UsageState {
        let path = Self.path
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder.toki.decode(UsageState.self, from: data) else {
            return UsageState()
        }
        return state
    }

    static func save(_ state: UsageState) {
        let path = Self.path
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.toki.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension JSONDecoder {
    static var toki: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var toki: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct UsageFetchResponse {
    var snapshots: [AccountSnapshot]
    var apiCallKeys: Set<String>
    var fetchedAt: Date
}

struct AccountFetchResult {
    var snapshots: [AccountSnapshot]
    var apiCallKeys: [String]
}

enum UsageFetcher {
    private static let claudeRefreshInterval: TimeInterval = 7.5 * 60
    private static let defaultAPIRefreshInterval: TimeInterval = 5 * 60

    static func fetch(
        config: AppConfig,
        state: UsageState,
        previousSnapshots: [AccountSnapshot],
        minimumRefreshInterval: TimeInterval?
    ) async -> UsageFetchResponse {
        let accounts = config.accounts
        let previousByID = Dictionary(uniqueKeysWithValues: previousSnapshots.map { ($0.id, $0) })
        let fetchedAt = Date()
        return await withTaskGroup(of: (Int, AccountFetchResult).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    await (
                        index,
                        snapshots(
                            for: account,
                            config: config,
                            state: state,
                            previousByID: previousByID,
                            lastCalledAt: state.apiLastCalledAt,
                            now: fetchedAt,
                            minimumRefreshInterval: minimumRefreshInterval
                        )
                    )
                }
            }

            var byIndex: [Int: AccountFetchResult] = [:]
            for await result in group {
                byIndex[result.0] = result.1
            }
            let orderedResults = accounts.indices.compactMap { byIndex[$0] }
            return UsageFetchResponse(
                snapshots: orderedResults.flatMap(\.snapshots),
                apiCallKeys: Set(orderedResults.flatMap(\.apiCallKeys)),
                fetchedAt: fetchedAt
            )
        }
    }

    private static func snapshots(
        for account: AccountConfig,
        config: AppConfig,
        state: UsageState,
        previousByID: [String: AccountSnapshot],
        lastCalledAt: [String: Date],
        now: Date,
        minimumRefreshInterval: TimeInterval?
    ) async -> AccountFetchResult {
        let cacheKey = apiCacheKey(for: account)
        if let cacheKey,
           let previous = previousSnapshots(for: account, previousByID: previousByID),
           !isDue(
                account: account,
                cacheKey: cacheKey,
                lastCalledAt: lastCalledAt,
                now: now,
                minimumRefreshInterval: minimumRefreshInterval
           ) {
            return AccountFetchResult(snapshots: previous, apiCallKeys: [])
        }

        let attemptedKeys = cacheKey.map { [$0] } ?? []
        do {
            let snapshots: [AccountSnapshot]
            switch account.provider {
            case .claudeCode:
                snapshots = try await ClaudeCodeUsageClient(account: account, labels: config.accountLabels ?? []).snapshots()
            case .chatgpt, .claude, .manual:
                snapshots = [consumerSnapshot(for: account, state: state)]
            case .openai:
                snapshots = [try await OpenAIUsageClient(account: account).snapshot()]
            case .codex:
                snapshots = [try await CodexUsageClient(account: account).snapshot()]
            case .anthropic:
                snapshots = [try await AnthropicUsageClient(account: account).snapshot()]
            }
            if containsRateLimit(snapshots),
               let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: snapshots, apiCallKeys: attemptedKeys)
        } catch let error as HTTPStatusError where error.statusCode == 429 {
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        } catch where isRateLimit(error) {
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        } catch {
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        }
    }

    private static func apiCacheKey(for account: AccountConfig) -> String? {
        switch account.provider {
        case .chatgpt, .claude, .manual:
            return nil
        case .claudeCode, .codex, .openai, .anthropic:
            return "\(account.provider.rawValue):\(account.id)"
        }
    }

    private static func isDue(
        account: AccountConfig,
        cacheKey: String,
        lastCalledAt: [String: Date],
        now: Date,
        minimumRefreshInterval: TimeInterval?
    ) -> Bool {
        guard let lastCalledAt = lastCalledAt[cacheKey] else { return true }
        return now.timeIntervalSince(lastCalledAt) >= (minimumRefreshInterval ?? refreshInterval(for: account.provider))
    }

    private static func refreshInterval(for provider: Provider) -> TimeInterval {
        switch provider {
        case .claudeCode:
            return claudeRefreshInterval
        case .codex, .openai, .anthropic:
            return defaultAPIRefreshInterval
        case .chatgpt, .claude, .manual:
            return 0
        }
    }

    private static func previousSnapshots(for account: AccountConfig, previousByID: [String: AccountSnapshot]) -> [AccountSnapshot]? {
        switch account.provider {
        case .claudeCode:
            let snapshots = previousByID.values
                .filter { $0.provider == .claudeCode && ($0.id == account.id || $0.id.hasPrefix("claude-")) }
                .sorted { $0.id < $1.id }
            return snapshots.isEmpty ? nil : snapshots
        default:
            return previousByID[account.id].map { [$0] }
        }
    }

    private static func containsRateLimit(_ snapshots: [AccountSnapshot]) -> Bool {
        snapshots.contains { snapshot in
            isRateLimitDescription(snapshot.subtitle)
                || snapshot.metrics.contains { isRateLimitDescription($0.value) }
        }
    }

    private static func isRateLimit(_ error: Error) -> Bool {
        if let httpError = error as? HTTPStatusError {
            return httpError.statusCode == 429
        }
        return isRateLimitDescription(error.localizedDescription)
    }

    private static func isRateLimitDescription(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("http 429")
            || normalized.contains("status 429")
            || normalized.contains("429")
    }

    private static func errorSnapshot(for account: AccountConfig, error: Error) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "Unavailable",
            subtitle: error.localizedDescription,
            remainingRatio: nil,
            metrics: account.notes.map { [MetricLine(label: "Note", value: $0)] } ?? [],
            isError: true
        )
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

struct CodexUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let credentials = try CodexCredentialReader.readCredentials(account: account)
        let payload = try CodexAppServerClient.fetch()
        let usage = CodexUsage(json: payload.usage ?? [:])
        let rateLimits = CodexRateLimits(json: payload.rateLimits ?? [:])
        guard usage.hasUsage || rateLimits.hasUsage else {
            throw LocalizedErrorMessage("Codex usage unavailable")
        }

        let primary: String
        if let rateLimitPrimary = rateLimits.primary {
            primary = rateLimitPrimary
        } else if let todayTokens = usage.todayTokens {
            primary = "\(formatCompact(todayTokens)) tokens today"
        } else if let lifetimeTokens = usage.summaryMetric("lifetime_tokens", "lifetimeTokens") {
            primary = "\(formatCompact(lifetimeTokens)) lifetime tokens"
        } else {
            primary = "Usage available"
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .codex,
            primary: primary,
            subtitle: rateLimits.subtitle ?? credentials.email ?? "OpenAI Codex usage",
            remainingRatio: rateLimits.remainingRatio,
            progressRatio: rateLimits.progressRatio,
            metrics: rateLimits.metrics + usage.metrics,
            accountInfo: CodexCredentialReader.accountInfo(from: credentials) + CodexAccountInfo.lines(from: payload.account)
        )
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
                switchCommand: account.claudeSwapCommand,
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
            switchCommand: account.claudeSwapCommand,
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
        return try? JSONDecoder.toki.decode(ClaudeSwapSequence.self, from: data)
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
        return Toki.emailIdentifier(in: json)
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

        if let email = Toki.emailIdentifier(in: json) {
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

struct CodexCredentials {
    var accessToken: String
    var accountID: String?
    var authMode: String?
    var email: String?
    var source: String
}

enum CodexCredentialReader {
    static func readCredentials(account: AccountConfig) throws -> CodexCredentials {
        if let token = try explicitAccessToken(account: account) {
            return CodexCredentials(
                accessToken: token,
                accountID: nil,
                authMode: nil,
                email: nil,
                source: "Configured token"
            )
        }

        let path = expandedPath(account.codexAuthPath ?? "~/.codex/auth.json")
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalizedErrorMessage("Missing Codex auth at \(path)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw LocalizedErrorMessage("No Codex OAuth access token found")
        }

        let idToken = tokens["id_token"] as? String
        let claims = idToken.flatMap(jwtPayload)
        return CodexCredentials(
            accessToken: accessToken,
            accountID: tokens["account_id"] as? String,
            authMode: json["auth_mode"] as? String,
            email: claims.flatMap { firstString(in: $0, keys: ["email", "preferred_username", "username"]) },
            source: path
        )
    }

    static func accountInfo(from credentials: CodexCredentials) -> [MetricLine] {
        var lines: [MetricLine] = []
        if let authMode = credentials.authMode {
            lines.append(MetricLine(label: "Auth", value: authMode))
        }
        if let email = credentials.email {
            lines.append(MetricLine(label: "Email", value: email))
        }
        if let accountID = credentials.accountID {
            lines.append(MetricLine(label: "Account", value: compactIdentifier(accountID)))
        }
        lines.append(MetricLine(label: "Source", value: credentials.source))
        return lines
    }

    private static func explicitAccessToken(account: AccountConfig) throws -> String? {
        if let apiKey = account.apiKey, !apiKey.isEmpty {
            return apiKey
        }
        if let envName = account.apiKeyEnv,
           let value = ProcessInfo.processInfo.environment[envName],
           !value.isEmpty {
            return value
        }
        if let command = account.apiKeyCommand, !command.isEmpty {
            let value = try SecretResolver.runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

struct CodexAppServerPayload {
    var usage: Any?
    var rateLimits: Any?
    var account: Any?
}

enum CodexAppServerClient {
    static func fetch() throws -> CodexAppServerPayload {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Toki","version":"\#(appVersion)"},"capabilities":{"experimentalApi":true}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"initialized","params":null}"#
        let usage = #"{"jsonrpc":"2.0","id":2,"method":"account/usage/read","params":null}"#
        let rateLimits = #"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":null}"#
        let account = #"{"jsonrpc":"2.0","id":4,"method":"account/read","params":{}}"#
        let path = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let command = """
        ( printf '%s\\n' '\(shellEscaped(initialize))'; \
        sleep 0.2; \
        printf '%s\\n' '\(shellEscaped(initialized))'; \
        sleep 0.2; \
        printf '%s\\n' '\(shellEscaped(usage))' '\(shellEscaped(rateLimits))' '\(shellEscaped(account))'; \
        sleep 5 ) | PATH="\(path)" codex app-server --stdio
        """

        let output = try SecretResolver.runShell(command)
        var payload = CodexAppServerPayload()
        var errors: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int else {
                continue
            }

            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Codex app-server request \(id) failed"
                errors.append(message)
                continue
            }

            guard let result = json["result"] else { continue }
            switch id {
            case 2:
                payload.usage = result
            case 3:
                payload.rateLimits = result
            case 4:
                payload.account = result
            default:
                continue
            }
        }

        if payload.usage == nil && payload.rateLimits == nil {
            throw LocalizedErrorMessage(errors.first ?? "Codex app-server did not return usage")
        }
        return payload
    }
}

struct CodexAccountInfo {
    static func lines(from value: Any?) -> [MetricLine] {
        guard let data = value as? [String: Any],
              let account = data["account"] as? [String: Any] else {
            return []
        }

        var lines: [MetricLine] = []
        if let type = firstValue(account, keys: ["type"]) as? String {
            lines.append(MetricLine(label: "Account type", value: type))
        }
        if let plan = firstValue(account, keys: ["planType"]) as? String {
            lines.append(MetricLine(label: "Plan", value: plan))
        }
        if let email = firstValue(account, keys: ["email"]) as? String, !email.isEmpty {
            lines.append(MetricLine(label: "Email", value: email))
        }
        return lines
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

struct CodexUsage {
    var metrics: [MetricLine] = []
    var todayTokens: Double?
    private var summary: [String: Any] = [:]

    var hasUsage: Bool {
        !metrics.isEmpty || todayTokens != nil
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }
        summary = (data["summary"] as? [String: Any]) ?? [:]

        let buckets = dailyBuckets(in: data)
        if let todayBucket = bucketForToday(buckets) {
            todayTokens = optionalNumber(firstValue(todayBucket, keys: ["tokens"]))
        } else if let latestBucket = latestBucket(buckets) {
            todayTokens = optionalNumber(firstValue(latestBucket, keys: ["tokens"]))
        }

        if let todayTokens {
            metrics.append(MetricLine(label: "Today", value: "\(formatCompact(todayTokens)) tokens"))
        }
        if let lifetime = summaryMetric("lifetime_tokens", "lifetimeTokens") {
            metrics.append(MetricLine(label: "Lifetime", value: "\(formatCompact(lifetime)) tokens"))
        }
        if let peak = summaryMetric("peak_daily_tokens", "peakDailyTokens") {
            metrics.append(MetricLine(label: "Peak day", value: "\(formatCompact(peak)) tokens"))
        }
        if let longestTurn = summaryMetric("longest_running_turn_sec", "longestRunningTurnSec"),
           longestTurn > 0 {
            metrics.append(MetricLine(label: "Longest turn", value: formatDuration(seconds: longestTurn)))
        }
        if let currentStreak = summaryMetric("current_streak_days", "currentStreakDays") {
            metrics.append(MetricLine(label: "Current streak", value: "\(Int(currentStreak)) days"))
        }
        if let longestStreak = summaryMetric("longest_streak_days", "longestStreakDays") {
            metrics.append(MetricLine(label: "Longest streak", value: "\(Int(longestStreak)) days"))
        }
    }

    func summaryMetric(_ keys: String...) -> Double? {
        optionalNumber(firstValue(summary, keys: keys))
    }

    private func dailyBuckets(in data: [String: Any]) -> [[String: Any]] {
        for key in ["daily_usage_buckets", "dailyUsageBuckets"] {
            if let buckets = data[key] as? [[String: Any]] {
                return buckets
            }
        }
        return []
    }

    private func bucketForToday(_ buckets: [[String: Any]]) -> [String: Any]? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return buckets.first { bucket in
            guard let startDate = firstValue(bucket, keys: ["start_date", "startDate"]) as? String else {
                return false
            }
            return startDate.hasPrefix(today)
        }
    }

    private func latestBucket(_ buckets: [[String: Any]]) -> [String: Any]? {
        buckets.max { lhs, rhs in
            let lhsDate = (firstValue(lhs, keys: ["start_date", "startDate"]) as? String) ?? ""
            let rhsDate = (firstValue(rhs, keys: ["start_date", "startDate"]) as? String) ?? ""
            return lhsDate < rhsDate
        }
    }
}

struct CodexRateLimits {
    var metrics: [MetricLine] = []
    var primary: String?
    var subtitle: String?
    var remainingRatio: Double?
    var progressRatio: Double?

    var hasUsage: Bool {
        !metrics.isEmpty || primary != nil
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }
        let limits = preferredLimit(from: data)
        let plan = firstValue(limits, keys: ["planType"]) as? String
        subtitle = plan.map { "OpenAI Codex - \($0)" } ?? "OpenAI Codex rate limits"

        if let primaryWindow = limits["primary"] as? [String: Any] {
            appendWindow(primaryWindow, fallbackLabel: "5h")
        }
        if let secondaryWindow = limits["secondary"] as? [String: Any] {
            appendWindow(secondaryWindow, fallbackLabel: "7d")
        }
        if let resetCredits = data["rateLimitResetCredits"] as? [String: Any],
           let count = optionalNumber(firstValue(resetCredits, keys: ["availableCount"])) {
            metrics.append(MetricLine(label: "Resets", value: "\(Int(count)) available"))
        }
        if let credits = limits["credits"] as? [String: Any] {
            appendCredits(credits)
        }
        if let reached = firstValue(limits, keys: ["rateLimitReachedType"]) as? String, !reached.isEmpty {
            metrics.append(MetricLine(label: "Limit", value: reached))
        }
    }

    private func preferredLimit(from data: [String: Any]) -> [String: Any] {
        if let byID = data["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any] {
            return codex
        }
        return (data["rateLimits"] as? [String: Any]) ?? [:]
    }

    private mutating func appendWindow(_ window: [String: Any], fallbackLabel: String) {
        guard let usedPercent = optionalNumber(firstValue(window, keys: ["usedPercent"])) else {
            return
        }

        let label = windowLabel(window, fallback: fallbackLabel)
        let clampedUsed = max(0, min(100, usedPercent))
        if primary == nil {
            primary = "\(Int((100 - clampedUsed).rounded()))% left"
            progressRatio = clampedUsed / 100
            remainingRatio = 1 - (clampedUsed / 100)
        }

        var value = "\(Int(clampedUsed.rounded()))% used"
        if let reset = resetDescriptionFromUnix(firstValue(window, keys: ["resetsAt"])) {
            value += " - resets \(reset)"
        }
        metrics.append(MetricLine(label: label, value: value))
    }

    private func windowLabel(_ window: [String: Any], fallback: String) -> String {
        guard let minutes = optionalNumber(firstValue(window, keys: ["windowDurationMins"])) else {
            return fallback
        }
        if minutes == 300 { return "5h" }
        if minutes == 10080 { return "7d" }
        if minutes >= 1440 { return "\(Int(minutes / 1440))d" }
        if minutes >= 60 { return "\(Int(minutes / 60))h" }
        return "\(Int(minutes))m"
    }

    private mutating func appendCredits(_ credits: [String: Any]) {
        if let unlimited = credits["unlimited"] as? Bool, unlimited {
            metrics.append(MetricLine(label: "Credits", value: "Unlimited"))
            return
        }
        if let hasCredits = credits["hasCredits"] as? Bool {
            metrics.append(MetricLine(label: "Credits", value: hasCredits ? "Available" : "Depleted"))
        }
        if let balance = credits["balance"] as? String, !balance.isEmpty {
            metrics.append(MetricLine(label: "Balance", value: balance))
        }
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
    static func switchTo(target: String, command configuredCommand: String?) throws {
        let path = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let executable = configuredCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "claude-swap"
        let command = "PATH=\"\(path)\" '\(shellEscaped(executable))' --switch-to '\(shellEscaped(target))'"
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

    await MainActor.run { debugLogHandler?("GET \(url.path)") }

    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
    await MainActor.run { debugLogHandler?("\(statusCode) \(url.path) - \(bodyPreview.prefix(80))") }

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw HTTPStatusError(statusCode: http.statusCode, body: body)
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

func firstValue(_ dict: [String: Any], keys: [String]) -> Any? {
    for key in keys {
        if let value = dict[key] {
            return value
        }
    }
    return nil
}

func resetDescription(_ value: Any?) -> String? {
    guard let raw = value as? String,
          let resetDate = ISO8601DateFormatter().date(from: raw) else {
        return nil
    }
    return resetDescription(for: resetDate)
}

func resetDescriptionFromUnix(_ value: Any?) -> String? {
    guard let seconds = optionalNumber(value) else { return nil }
    return resetDescription(for: Date(timeIntervalSince1970: seconds))
}

func resetDescription(for resetDate: Date) -> String {
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

func emailAddress(in snapshot: AccountSnapshot) -> String? {
    if let email = snapshot.accountInfo.first(where: { $0.label == "Email" })?.value,
       email.contains("@") {
        return email
    }
    if snapshot.subtitle.contains("@") {
        return snapshot.subtitle
    }
    return nil
}

func organizationName(in snapshot: AccountSnapshot) -> String? {
    snapshot.accountInfo.first(where: { $0.label == "Org" })?.value
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

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
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

func formatDuration(seconds: Double) -> String {
    let total = max(Int(seconds.rounded()), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m"
    }
    return "\(total)s"
}

func remainingText(from value: String) -> String {
    if let usedPercent = usedPercent(in: value) {
        let remaining = max(0, min(100, 100 - Int(usedPercent.rounded())))
        return "\(remaining)% left"
    }
    return value.components(separatedBy: " - ").first ?? value
}

func usedPercent(in value: String) -> Double? {
    guard let percentIndex = value.firstIndex(of: "%") else { return nil }
    let prefix = value[..<percentIndex]
    let candidates = prefix.split { character in
        !character.isNumber && character != "."
    }
    return candidates.last.flatMap { Double($0) }
}

struct LocalizedErrorMessage: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct HTTPStatusError: LocalizedError {
    var statusCode: Int
    var body: String

    var errorDescription: String? {
        "HTTP \(statusCode): \(body.prefix(140))"
    }
}

struct PointerOnHoverModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointerOnHover() -> some View {
        modifier(PointerOnHoverModifier())
    }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            overview
            if let configError = store.configError {
                ErrorBanner(message: configError)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.snapshots) { snapshot in
                            AccountCard(snapshot: snapshot, store: store) { id in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                        proxy.scrollTo(id, anchor: .top)
                                    }
                                }
                            }
                            .id(snapshot.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.trailing, 2)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.snapshots.map(\.id))
                }
                .frame(maxHeight: accountListHeight())
            }

            if store.debugMode {
                debugPanel
            }
        }
        .padding(12)
        .frame(width: popoverWidth(), height: popoverHeight(), alignment: .top)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            TokiLogoMark(size: 34)
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("/toki")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    Text("v\(appVersion)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .onTapGesture(count: 5) {
                            store.toggleDebug()
                        }
                }
            }
            Spacer()
            headerControls
        }
    }

    private var headerControls: some View {
        HStack(spacing: 5) {
            Button {
                store.refresh(minimumRefreshInterval: 60)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Refresh")
            .pointerOnHover()

            Button {
                ConfigLoader.openInDefaultEditor()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Open config")
            .pointerOnHover()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.red.opacity(0.42), lineWidth: 1)
            )
            .help("Quit")
            .pointerOnHover()
        }
    }

    private var overview: some View {
        HStack(spacing: 8) {
            StatBlock(title: "Accounts", value: "\(store.snapshots.count)", systemImage: "person.2")
            StatBlock(title: "Lowest", value: lowestRemainingText, systemImage: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    private var lowestRemainingText: String {
        guard let ratio = store.snapshots.compactMap(\.remainingRatio).min() else { return "--" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "ant.fill")
                    .foregroundStyle(.orange)
                Text("Debug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Clear") {
                    store.debugLog.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .pointerOnHover()
            }
            if store.debugLog.isEmpty {
                Text("No log entries")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.debugLog) { entry in
                            HStack(spacing: 6) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

struct AccountCard: View {
    var snapshot: AccountSnapshot
    @ObservedObject var store: UsageStore
    var onExpand: (String) -> Void = { _ in }
    @State private var isExpanded = false
    @State private var isEditingAlias = false
    @State private var aliasDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse account" : "Show account details")
                .pointerOnHover()
                .padding(.top, 8)

                AccountBadge(snapshot: snapshot, size: 26)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    aliasEditor

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(snapshot.provider.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            if store.debugMode && snapshot.isError {
                                Image(systemName: "exclamationmark.bubble.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let secondaryIdentifier {
                            Text(secondaryIdentifier)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 12)

                collapsedSummary

                if let switchTarget = snapshot.switchTarget {
                    VStack(alignment: .trailing, spacing: 4) {
                        if snapshot.isError {
                            StatusBadge(text: "not connected")
                        }
                        Button {
                            store.switchClaudeAccount(target: switchTarget, command: snapshot.switchCommand)
                        } label: {
                            Label("Switch", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Switch Claude Code to this account")
                        .pointerOnHover()
                    }
                }
            }

            if let ratio = progressRatio {
                ProgressView(value: ratio)
                    .tint(progressTint(ratio))
                    .scaleEffect(y: 0.65, anchor: .center)
            }

            if isExpanded {
                Divider()
                    .padding(.top, 1)

                HStack(alignment: .center, spacing: 8) {
                    Text(snapshot.primary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(snapshot.isError ? .red : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer()
                    ProviderPill(provider: snapshot.provider)
                }

                if !snapshot.metrics.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(snapshot.metrics) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }

                if !snapshot.accountInfo.isEmpty {
                    Divider()
                        .padding(.vertical, 1)
                    VStack(spacing: 3) {
                        ForEach(snapshot.accountInfo) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }

                if store.debugMode && snapshot.isError {
                    Divider()
                        .padding(.vertical, 1)
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Debug")
                                .foregroundStyle(.orange)
                                .frame(width: 42, alignment: .leading)
                            Text(snapshot.subtitle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        ForEach(snapshot.metrics) { metric in
                            MetricRow(metric: metric)
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                        }
                    }
                    .foregroundStyle(.secondary)
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

                        Button {
                            store.resetUsage(accountID: snapshot.id)
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .help("Reset usage for this account")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerOnHover()
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(
            TapGesture().onEnded {
                guard !isEditingAlias else { return }
                toggleExpanded()
            },
            including: .gesture
        )
        .pointerOnHover()
    }

    @ViewBuilder
    private var aliasEditor: some View {
        HStack(spacing: 5) {
            if isEditingAlias {
                TextField("Alias", text: $aliasDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 120)
                    .onSubmit(saveAlias)
                Button {
                    saveAlias()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .help("Save alias")
                .pointerOnHover()
            } else {
                Text(accountIdentifier)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    aliasDraft = accountIdentifier
                    isEditingAlias = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit alias")
                .pointerOnHover()
            }
        }
    }

    private var accountIdentifier: String {
        return snapshot.name
    }

    private var secondaryIdentifier: String? {
        emailAddress(in: snapshot) ?? (snapshot.subtitle.isEmpty ? nil : snapshot.subtitle)
    }

    private var collapsedStatus: String {
        snapshot.isError ? "Not connected" : snapshot.primary
    }

    @ViewBuilder
    private var collapsedSummary: some View {
        if snapshot.isError && snapshot.switchTarget != nil {
            EmptyView()
        } else if snapshot.isError {
            Text(collapsedStatus)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                QuotaSummaryLine(label: "current", value: currentSessionAvailability, resetHint: currentResetTime)
                QuotaSummaryLine(label: "weekly", value: weeklyAvailability, resetHint: weeklyResetTime)
            }
        }
    }

    private var currentSessionAvailability: String {
        availabilityText(for: ["Daily", "5h", "Today"]) ?? snapshot.primary
    }

    private var weeklyAvailability: String {
        availabilityText(for: ["7d", "Weekly", "Week"]) ?? "--"
    }

    private func availabilityText(for labels: Set<String>) -> String? {
        guard let metric = snapshot.metrics.first(where: { labels.contains($0.label) }) else {
            return nil
        }
        return remainingText(from: metric.value)
    }

    private var currentResetTime: String? {
        if let resetMetric = snapshot.metrics.first(where: { $0.label == "Reset" }) {
            return resetMetric.value
        }
        if let metric = snapshot.metrics.first(where: { ["Daily", "5h", "Today"].contains($0.label) }),
           let range = metric.value.range(of: "resets ") {
            return String(metric.value[range.upperBound...])
        }
        return nil
    }

    private var weeklyResetTime: String? {
        if let metric = snapshot.metrics.first(where: { ["7d", "Weekly", "Week"].contains($0.label) }),
           let range = metric.value.range(of: "resets ") {
            return String(metric.value[range.upperBound...])
        }
        return nil
    }

    private var progressRatio: Double? {
        snapshot.progressRatio ?? snapshot.remainingRatio.map { 1 - $0 }
    }

    private var statusColor: Color {
        if snapshot.isError { return .red }
        guard let remaining = snapshot.remainingRatio else { return .secondary }
        if remaining <= 0.15 { return .red }
        if remaining <= 0.40 { return .orange }
        return .green
    }

    private var borderColor: Color {
        if snapshot.isError { return Color.red.opacity(0.25) }
        return Color.primary.opacity(0.08)
    }

    private func progressTint(_ ratio: Double) -> Color {
        if ratio >= 0.85 { return .red }
        if ratio >= 0.60 { return .orange }
        return .green
    }

    private func saveAlias() {
        store.renameAccount(snapshot: snapshot, alias: aliasDraft)
        isEditingAlias = false
    }

    private func toggleExpanded() {
        let willExpand = !isExpanded
        withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded = willExpand
        }
        if willExpand {
            onExpand(snapshot.id)
        }
    }
}

struct StatusBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.red)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.red.opacity(0.22), lineWidth: 1))
            .fixedSize()
    }
}

struct QuotaSummaryLine: View {
    var label: String
    var value: String
    var resetHint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                valueView
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let resetHint {
                Text(resetHint)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if let availability = availabilityPercent {
            HStack(spacing: 3) {
                Text("\(availability)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(availabilityColor(for: availability))
                Text("left")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var availabilityPercent: Int? {
        guard value.hasSuffix(" left"),
              let percentIndex = value.firstIndex(of: "%"),
              let percent = Int(value[..<percentIndex]) else {
            return nil
        }
        return percent
    }
}

struct StatBlock: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

struct ErrorBanner: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

struct ProviderPill: View {
    var provider: Provider

    var body: some View {
        HStack(spacing: 5) {
            ProviderLogo(provider: provider, size: 11)
            Text(provider.displayName)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .foregroundStyle(.secondary)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
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
        .pointerOnHover()
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
            case .codex:
                CodexLogoMark(size: size)
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

enum CodexLogoAsset {
    static let image: NSImage? = loadImage()

    private static func loadImage() -> NSImage? {
        let executableResourceURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/codex-logo.svg")
        let urls = [
            Bundle.module.url(forResource: "codex-logo", withExtension: "svg"),
            Bundle.main.url(forResource: "codex-logo", withExtension: "svg"),
            Bundle.main.resourceURL?.appendingPathComponent("codex-logo.svg"),
            executableResourceURL
        ]

        for url in urls.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

enum TokiLogoAsset {
    static let image: NSImage? = loadImage()

    private static func loadImage() -> NSImage? {
        let executableResourceURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/toki-logo.svg")
        let urls = [
            Bundle.module.url(forResource: "toki-logo", withExtension: "svg"),
            Bundle.main.url(forResource: "toki-logo", withExtension: "svg"),
            Bundle.main.resourceURL?.appendingPathComponent("toki-logo.svg"),
            executableResourceURL
        ]

        for url in urls.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

struct TokiLogoMark: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let image = TokiLogoAsset.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: "wallet.pass")
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("/toki")
    }
}

struct CodexLogoMark: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let image = CodexLogoAsset.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                OpenAILogoMark()
                    .foregroundStyle(Color(red: 0.48, green: 0.61, blue: 1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Codex")
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

func availabilityColor(for percent: Int) -> Color {
    if percent > 75 {
        return .primary
    }
    if percent > 42 {
        return Color(red: 1.0, green: 0.64, blue: 0.18)
    }
    return Color(red: 1.0, green: 0.48, blue: 0.50)
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
    min(350, max(320, (NSScreen.main?.visibleFrame.width ?? 350) - 32))
}

func popoverHeight() -> CGFloat {
    min(500, max(340, (NSScreen.main?.visibleFrame.height ?? 500) - 96))
}

func accountListHeight() -> CGFloat {
    max(240, popoverHeight() - 78)
}

func sortedByAvailability(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
    snapshots.enumerated()
        .sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element

            if left.isError != right.isError {
                return !left.isError
            }

            let leftRemaining = left.remainingRatio
            let rightRemaining = right.remainingRatio
            if (leftRemaining == nil) != (rightRemaining == nil) {
                return leftRemaining != nil
            }

            if let leftRemaining, let rightRemaining, leftRemaining != rightRemaining {
                return leftRemaining > rightRemaining
            }

            return lhs.offset < rhs.offset
        }
        .map(\.element)
}

func menuBarStatus(for snapshots: [AccountSnapshot]) -> String {
    let entries = menuBarEntries(for: snapshots)
    guard !entries.isEmpty else { return "Toki --" }
    return entries.map { "\($0.value)" }.joined(separator: "  ")
}

struct MenuBarStatusEntry: Identifiable {
    var id: Provider { provider }
    var provider: Provider
    var value: String
}

func menuBarEntries(for snapshots: [AccountSnapshot]) -> [MenuBarStatusEntry] {
    let activeClaude = snapshots.first {
        $0.provider.isClaudeAccount && $0.switchTarget == nil && !$0.isError
    }
    let fallbackClaude = snapshots.first {
        $0.provider.isClaudeAccount && !$0.isError
    }
    let codex = snapshots.first {
        $0.provider == .codex && !$0.isError
    }

    let segments = [activeClaude ?? fallbackClaude, codex].compactMap { $0 }

    return segments.map(menuBarEntry)
}

func menuBarPlaceholderEntries() -> [MenuBarStatusEntry] {
    [
        MenuBarStatusEntry(provider: .claudeCode, value: "--"),
        MenuBarStatusEntry(provider: .codex, value: "--")
    ]
}

func menuBarEntry(for snapshot: AccountSnapshot) -> MenuBarStatusEntry {
    let value = snapshot.remainingRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
    return MenuBarStatusEntry(provider: snapshot.provider, value: value)
}

struct MenuBarStatusView: View {
    var entries: [MenuBarStatusEntry]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    ProviderLogo(provider: entry.provider, size: 13)
                    Text(entry.value)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusHostingView: PassthroughHostingView<MenuBarStatusView>?
    private let popover = NSPopover()
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(entries: menuBarPlaceholderEntries())
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth(), height: popoverHeight())
        popover.contentViewController = NSHostingController(rootView: MenuContentView(store: store))
        popover.delegate = self

        Task { @MainActor in
            for await snapshots in store.$snapshots.values {
                let entries = menuBarEntries(for: snapshots)
                updateStatusItem(entries: entries.isEmpty ? menuBarPlaceholderEntries() : entries)
            }
        }
    }

    private func updateStatusItem(entries: [MenuBarStatusEntry]) {
        guard let button = statusItem.button else { return }
        let content = MenuBarStatusView(entries: entries)
        let hostingView: PassthroughHostingView<MenuBarStatusView>
        if let existing = statusHostingView {
            existing.rootView = content
            hostingView = existing
        } else {
            hostingView = PassthroughHostingView(rootView: content)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.appearance = NSApp.effectiveAppearance
            button.addSubview(hostingView)
            statusHostingView = hostingView
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let width = max(54, ceil(fittingSize.width) + 6)
        statusItem.length = width
        statusItem.button?.title = ""
        statusItem.button?.image = nil
        hostingView.frame = NSRect(x: 3, y: 0, width: width - 6, height: button.bounds.height)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            store.refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
