import Foundation

enum GrokUsageClient {
    private struct Billing: Decodable {
        struct Config: Decodable {
            struct Period: Decodable {
                let type: String
                let end: String?
            }

            let creditUsagePercent: Double
            let currentPeriod: Period
        }

        let config: Config
        let subscription_tier: String?
    }

    static func snapshot(for account: AccountConfig, cancellation: CLIJSONProcess.Cancellation) throws -> AccountSnapshot {
        guard let executable = UsageFetcher.installedCLI(named: "grok") else {
            throw LocalizedErrorMessage("Install Grok Build and sign in to read its usage.")
        }
        let (workspace, environment) = try CLIJSONProcess.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let emailBeforeRequest = cachedEmail(environment: environment)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workspace
        process.environment = environment
        process.arguments = ["agent", "stdio", "--leader-socket", workspace.appendingPathComponent("grok.sock").path]
        let session = try CLIJSONProcess(process: process, label: "Grok Build", cancellation: cancellation)
        defer { session.close() }

        let initialized = try session.request(
            id: 1, method: "initialize",
            params: #"{"protocolVersion":1,"clientCapabilities":{}}"#, timeout: 8
        )
        guard initialized.result != nil, initialized.error == nil else {
            throw LocalizedErrorMessage("Grok Build could not initialize its usage connection.")
        }
        let reply = try session.request(id: 2, method: "_x.ai/billing", params: "{}", timeout: 10)
        let email = emailBeforeRequest == cachedEmail(environment: environment) ? emailBeforeRequest : nil
        guard let result = reply.result, let snapshot = Self.snapshot(for: account, billing: result, email: email) else {
            throw LocalizedErrorMessage("Grok Build did not report a weekly allowance. Check /usage in Grok Build.")
        }
        return snapshot
    }

    private static func cachedEmail(environment: [String: String]) -> String? {
        guard environment["XAI_API_KEY"]?.isEmpty != false else { return nil }
        let home = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.grok"
        return (try? GrokCredentialReader.readCredentials(path: "\(home)/auth.json", requiresUniqueAccount: true))?.email
    }

    static func snapshot(for account: AccountConfig, billing: Any, email: String? = nil,
                         now: Date = Date()) -> AccountSnapshot? {
        guard JSONSerialization.isValidJSONObject(billing),
              let data = try? JSONSerialization.data(withJSONObject: billing),
              let response = try? JSONDecoder().decode(Billing.self, from: data),
              response.config.currentPeriod.type == "USAGE_PERIOD_TYPE_WEEKLY",
              response.config.creditUsagePercent.isFinite, response.config.creditUsagePercent >= 0 else { return nil }

        let reset = resetDate(response.config.currentPeriod.end)
        guard reset.map({ $0 > now }) ?? true else { return nil }
        let fraction = max(0, 1 - response.config.creditUsagePercent / 100)
        let window = RateLimitWindow(
            label: "7d", percentLeft: Int((fraction * 100).rounded()),
            resetHint: reset.map { "resets in \(resetDescription(for: $0))" },
            resetAt: reset, duration: 7 * 86_400
        )
        return AccountSnapshot(
            id: account.id, name: account.name, provider: .grok,
            primary: "\(window.percentLeft)% left",
            subtitle: response.subscription_tier ?? "Grok weekly allowance",
            remainingRatio: fraction, metrics: [], primaryWindow: window,
            weeklySubscriptionQuota: email.map { WeeklySubscriptionQuota(email: $0, ratio: fraction, window: window) }
        )
    }
}
