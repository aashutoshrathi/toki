import Foundation

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
        } catch let expiry as ClaudeSignInExpiredError {
            DiagnosticLogger.shared.record(.info, component: "usage", code: "claude_sign_in_expired",
                                           detail: "account=\(record.email ?? record.id) active=\(record.isActive)")
            return AccountSnapshot(
                id: record.id,
                name: record.displayName,
                provider: .claudeCode,
                primary: "Signed out",
                subtitle: record.email ?? expiry.localizedDescription,
                remainingRatio: nil,
                metrics: [MetricLine(label: "Sign-in", value: expiry.localizedDescription)],
                accountInfo: accountInfoLines(for: record),
                isError: true,
                switchTarget: switchTarget(for: record),
                switchCommand: account.claudeSwapCommand,
                emoji: record.label?.emoji,
                colorHex: record.label?.color,
                isSignInExpired: true
            )
        } catch {
            DiagnosticLogger.shared.record(.error, component: "usage", code: "claude_account_failed", detail: diagnosticErrorDetail(error))
            return AccountSnapshot(
                id: record.id,
                name: record.displayName,
                provider: .claudeCode,
                primary: "Unavailable",
                subtitle: record.email ?? describe(error),
                remainingRatio: nil,
                metrics: [MetricLine(label: "Error", value: describe(error))],
                accountInfo: accountInfoLines(for: record),
                isError: true,
                switchTarget: switchTarget(for: record),
                switchCommand: account.claudeSwapCommand,
                emoji: record.label?.emoji,
                colorHex: record.label?.color
            )
        }
    }

    private func describe(_ error: Error) -> String {
        guard let http = error as? HTTPStatusError, http.statusCode == 401 else {
            return error.localizedDescription
        }
        return "Anthropic rejected this sign-in. Open Claude Code and run /login, then refresh Toki."
    }

    enum Disposition: Equatable {
        case useToken(String)
        case expired(ClaudeSignInExpiredError)
    }

    static func disposition(for record: ClaudeCodeAccountRecord, now: Date = Date()) throws -> Disposition {
        if let loadError = record.loadError {
            throw LocalizedErrorMessage(loadError)
        }
        guard let credentials = record.credentials, !credentials.isEmpty else {
            throw LocalizedErrorMessage("No credentials found")
        }
        let token = try ClaudeCodeCredentialReader.extractToken(from: credentials)
        guard !token.isExpired(asOf: now) else {
            return .expired(ClaudeSignInExpiredError(accountLabel: record.email, isActiveAccount: record.isActive))
        }
        return .useToken(token.accessToken)
    }

    private func snapshot(for record: ClaudeCodeAccountRecord) async throws -> AccountSnapshot {
        let accessToken: String
        switch try Self.disposition(for: record) {
        case .expired(let expiry):
            throw expiry
        case .useToken(let token):
            accessToken = token
        }
        let json = try await requestJSON(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!,
            headers: Self.oauthHeaders(accessToken: accessToken)
        )
        let usage = ClaudeCodeUsage(json: json)
        guard usage.hasUsage else {
            throw LocalizedErrorMessage("Claude Code usage unavailable")
        }

        let primaryMetric = usage.primaryMetric ?? UsageMetric(label: "Daily", utilization: usage.worstUtilization ?? 0, resetDescription: nil)
        let usedRatio = max(0, min(1, primaryMetric.utilization / 100))
        let remainingRatio = max(0, min(1, 1 - usedRatio))
        let percentLeft = Int((remainingRatio * 100).rounded())
        let primary = "\(percentLeft)% left"
        let email = record.email ?? record.credentials.flatMap(ClaudeCodeCredentialReader.emailIdentifier)

        return AccountSnapshot(
            id: record.id,
            name: record.displayName,
            provider: .claudeCode,
            primary: primary,
            subtitle: email ?? "Claude Code OAuth usage",
            remainingRatio: remainingRatio,
            progressRatio: usedRatio,
            resetCreditsAvailable: usage.resetCreditsAvailable,
            resetCreditExpiry: usage.resetCreditExpiry,
            metrics: usage.metrics,
            accountInfo: accountInfoLines(for: record, credentials: record.credentials),
            switchTarget: switchTarget(for: record),
            switchCommand: account.claudeSwapCommand,
            emoji: record.label?.emoji,
            colorHex: record.label?.color,
            primaryWindow: usage.rateLimitWindows.first,
            secondaryWindow: usage.rateLimitWindows.dropFirst().first,
            modelWindows: usage.modelWindows
        )
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!

    static func oauthHeaders(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": claudeCodeSurfaceUserAgent
        ]
    }

    static func consumeRateLimitResetCredit(account: AccountConfig, recordID: String? = nil, creditID: String? = nil) async throws -> String {
        let records = ClaudeCodeAccountDiscovery.discover(config: account, labels: [])
        guard let record = records.first(where: { $0.id == recordID })
            ?? records.first(where: { $0.isActive })
            ?? records.first else {
            throw LocalizedErrorMessage("No Claude account found")
        }
        let accessToken: String
        switch try disposition(for: record) {
        case .expired(let expiry): throw expiry
        case .useToken(let token): accessToken = token
        }
        guard let organizationUUID = record.organizationUUID
            ?? record.credentials.flatMap(ClaudeCodeCredentialReader.organizationUUID) else {
            throw LocalizedErrorMessage("No Claude organization found for this account")
        }

        let headers = oauthHeaders(accessToken: accessToken)
        let grantID: String
        if let creditID {
            grantID = creditID
        } else {
            let json = try await requestJSON(url: usageURL, headers: headers)
            guard let discovered = ClaudeCodeUsage(json: json).resetGrantID else {
                throw LocalizedErrorMessage("No reset is available to redeem right now.")
            }
            grantID = discovered
        }

        let url = URL(string: "https://api.anthropic.com/api/organizations/\(organizationUUID)/reset_rate_limits")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember",
            "grant_id": grantID,
            "request_id": UUID().uuidString
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw LocalizedErrorMessage("Failed to redeem reset. \(body)")
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return payload?["result"] as? String ?? "unavailable"
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
