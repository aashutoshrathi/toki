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

    func consumeCodexResetCredit(accountID: String) {
        guard let account = config?.accounts.first(where: { $0.id == accountID }), account.provider == .codex,
              !resettingAccountIDs.contains(accountID) else {
            return
        }
        resettingAccountIDs.insert(accountID)
        Task {
            defer { resettingAccountIDs.remove(accountID) }
            let result = await Task.detached {
                Result { try CodexAppServerClient.consumeRateLimitResetCredit(account: account, creditID: nil) }
            }.value

            switch result {
            case .success(let outcome):
                appendEvent(kind: .reset, title: "Codex reset", detail: resetOutcomeDescription(outcome), deliveredNotification: false)
                refresh(keepsExistingSnapshots: true)
            case .failure(let error):
                DiagnosticLogger.shared.record(.error, component: "codex_reset", code: "consume_failed", detail: diagnosticErrorDetail(error))
                appendEvent(kind: .reset, title: "Codex reset failed", detail: error.localizedDescription, deliveredNotification: false)
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

    func removeAccount(accountID: String) {
        guard var config, let index = config.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        config.accounts.remove(at: index)
        do {
            try ConfigLoader.save(config)
            self.config = config
            usageState.accounts.removeValue(forKey: accountID)
            StateLoader.save(usageState)
            snapshots.removeAll { $0.id == accountID }
            updateDerivedState(for: snapshots)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "config", code: "remove_account_failed", detail: diagnosticErrorDetail(error))
            configError = "Could not remove account: \(error.localizedDescription)"
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
