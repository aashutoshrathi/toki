import Foundation

extension UsageStore {
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

    func consumeResetCredit(accountID: String) {
        guard !resettingAccountIDs.contains(accountID), let account = resetCapableAccount(for: accountID) else {
            return
        }
        resettingAccountIDs.insert(accountID)
        Task {
            defer { resettingAccountIDs.remove(accountID) }
            let result = await Task.detached { () -> Result<String, Error> in
                do {
                    if account.provider == .claudeCode {
                        return .success(try await ClaudeCodeUsageClient.consumeRateLimitResetCredit(account: account, recordID: accountID))
                    }
                    return .success(try await CodexAppServerClient.consumeRateLimitResetCredit(account: account, creditID: nil))
                } catch {
                    return .failure(error)
                }
            }.value

            let isClaude = account.provider == .claudeCode
            let title = isClaude ? "Claude reset" : "Codex reset"
            switch result {
            case .success(let outcome):
                let detail = isClaude ? claudeResetOutcomeDescription(outcome) : resetOutcomeDescription(outcome)
                appendEvent(kind: .reset, title: title, detail: detail, deliveredNotification: false)
                if isClaude {
                    refreshClaudeAfterReset(accountID: accountID)
                } else {
                    applyCodexResetOutcome(outcome, accountID: accountID)
                    refreshCodexAfterReset(accountID: accountID)
                }
            case .failure(let error):
                DiagnosticLogger.shared.record(.error, component: "reset", code: "consume_failed", detail: diagnosticErrorDetail(error))
                appendEvent(kind: .reset, title: "\(title) failed", detail: error.localizedDescription, deliveredNotification: false)
            }
        }
    }

    private func resetCapableAccount(for snapshotID: String) -> AccountConfig? {
        if let exact = config?.accounts.first(where: { $0.id == snapshotID }),
           exact.provider == .codex || exact.provider == .claudeCode {
            return exact
        }
        guard snapshots.first(where: { $0.id == snapshotID })?.provider == .claudeCode else { return nil }
        return config?.accounts.first { $0.provider == .claudeCode }
    }

    private func claudeResetOutcomeDescription(_ outcome: String) -> String {
        switch outcome {
        case "reset": return "Rate limit windows were reset."
        case "already_used": return "That reset was already redeemed."
        case "not_limited": return "No rate limit window needed a reset."
        case "cooldown": return "Another reset was redeemed too recently."
        case "ineligible": return "This account can't redeem a reset right now."
        default: return "Reset outcome: \(outcome)."
        }
    }

    private func refreshClaudeAfterReset(accountID: String) {
        for account in config?.accounts.filter({ $0.provider == .claudeCode }) ?? [] {
            usageState.apiLastCalledAt.removeValue(forKey: "\(Provider.claudeCode.rawValue):\(account.id)")
        }
        refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 0)
    }

    private func applyCodexResetOutcome(_ outcome: String, accountID: String) {
        guard outcome == "reset" || outcome == "alreadyRedeemed" || outcome == "noCredit" else {
            return
        }
        snapshots = snapshots.map { snapshot in
            guard snapshot.id == accountID else { return snapshot }
            return codexSnapshotAfterReset(snapshot, resetsQuota: outcome != "noCredit")
        }
        lastUpdated = Date()
        updateDerivedState(for: snapshots)
    }

    private func refreshCodexAfterReset(accountID: String) {
        // A normal refresh is allowed to reuse Codex data for five minutes. Redemption is a
        // mutation, so that cache is known-stale and must not survive the confirming read.
        usageState.apiLastCalledAt.removeValue(forKey: "codex:\(accountID)")
        if !isRefreshing {
            refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 0)
            return
        }

        Task { [weak self] in
            for _ in 0..<100 {
                guard let self else { return }
                if !self.isRefreshing {
                    self.refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 0)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func resetOutcomeDescription(_ outcome: String) -> String {
        switch outcome {
        case "reset": return "Rate limit windows were reset."
        case "nothingToReset": return "No rate limit window needed a reset."
        case "noCredit": return "No reset credits were available."
        case "alreadyRedeemed": return "That reset was already redeemed."
        default: return "Reset outcome: \(outcome)."
        }
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
        } else if !config.accounts.contains(where: { $0.provider == snapshot.provider }) {
            config.accounts.append(AccountConfig(id: snapshot.id, name: trimmed, provider: snapshot.provider))
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
            // recommendation/menu bar text and the status cache all embed account names -
            // without this they'd keep showing the old name until the next refresh.
            updateDerivedState(for: snapshots)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "config", code: "alias_save_failed", detail: diagnosticErrorDetail(error))
            configError = "Could not save alias: \(error.localizedDescription)"
        }
    }
}

func codexSnapshotAfterReset(_ snapshot: AccountSnapshot, resetsQuota: Bool) -> AccountSnapshot {
    guard snapshot.provider == .codex else { return snapshot }
    var updated = snapshot
    updated.resetCreditsAvailable = max(0, snapshot.resetCreditsAvailable - 1)
    // The consumed credit's expiry no longer applies. The next refresh will repopulate
    // resetCreditExpiry from the backend's remaining credits, but we can't fabricate it
    // locally, so clear it to avoid showing a stale deadline.
    if updated.resetCreditsAvailable == 0 {
        updated.resetCreditExpiry = nil
    }

    let windowLabels = Set([snapshot.primaryWindow?.label, snapshot.secondaryWindow?.label].compactMap { $0 })
    updated.metrics = snapshot.metrics.compactMap { metric in
        if metric.label == "Resets" {
            if updated.resetCreditsAvailable > 0 {
                var value = "\(updated.resetCreditsAvailable) available"
                if let expiry = updated.resetCreditExpiry {
                    value += " · expires \(resetDescription(for: expiry))"
                }
                var updatedMetric = metric
                updatedMetric.value = value
                return updatedMetric
            }
            return nil
        }
        if resetsQuota, windowLabels.contains(metric.label) {
            var updatedMetric = metric
            updatedMetric.value = "0% used"
            return updatedMetric
        }
        if resetsQuota, metric.label == "Limit" {
            return nil
        }
        return metric
    }

    guard resetsQuota else { return updated }
    updated.primary = "100% left"
    updated.remainingRatio = 1
    updated.progressRatio = 0
    updated.primaryWindow = snapshot.primaryWindow.map {
        RateLimitWindow(label: $0.label, percentLeft: 100, resetHint: nil)
    }
    updated.secondaryWindow = snapshot.secondaryWindow.map {
        RateLimitWindow(label: $0.label, percentLeft: 100, resetHint: nil)
    }
    return updated
}
