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
