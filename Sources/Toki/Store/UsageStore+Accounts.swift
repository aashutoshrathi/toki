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
        startResetRedeem(accountID: accountID, condition: nil, completion: nil)
    }

    @discardableResult
    private func startResetRedeem(
        accountID: String,
        condition: AutoRedeemCondition?,
        completion: ((Result<RedeemedReset, Error>) -> Void)?
    ) -> Bool {
        guard !resettingAccountIDs.contains(accountID), let account = resetCapableAccount(for: accountID) else {
            return false
        }
        resettingAccountIDs.insert(accountID)
        Task {
            defer { resettingAccountIDs.remove(accountID) }
            let result = await Task.detached { () -> Result<RedeemedReset, Error> in
                do {
                    if account.provider == .claudeCode {
                        return .success(try await ClaudeCodeUsageClient.consumeRateLimitResetCredit(account: account, recordID: accountID, condition: condition))
                    }
                    return .success(try await CodexAppServerClient.consumeRateLimitResetCredit(account: account, creditID: nil, condition: condition))
                } catch {
                    return .failure(error)
                }
            }.value

            let isClaude = account.provider == .claudeCode
            let title = isClaude ? "Claude reset" : "Codex reset"
            switch result {
            case .success(let redeemed):
                let outcome = redeemed.outcome
                let detail = isClaude ? claudeResetOutcomeDescription(outcome) : resetOutcomeDescription(outcome)
                appendEvent(kind: .reset, title: title, detail: detail, deliveredNotification: false)
                if !isClaude {
                    applyCodexResetOutcome(outcome, accountID: accountID)
                }
            case .failure(let error):
                DiagnosticLogger.shared.record(.error, component: "reset", code: "consume_failed", detail: diagnosticErrorDetail(error))
                appendEvent(kind: .reset, title: "\(title) failed", detail: error.localizedDescription, deliveredNotification: false)
            }
            // Nothing was spent, so a forced re-read would only replay a rate-limited snapshot and retry at once.
            if redeemSpentNothing(result) {
                completion?(result)
                return
            }
            if isClaude {
                refreshClaudeAfterReset()
            } else {
                refreshCodexAfterReset(accountID: accountID)
            }
            completion?(result)
        }
        return true
    }

    func autoRedeemResets(in snapshots: [AccountSnapshot], at date: Date) {
        scheduleExpiringResetCheck(for: snapshots, after: date)
        guard preferences.autoResetEnabled else {
            return
        }
        for snapshot in snapshots {
            guard !resettingAccountIDs.contains(snapshot.id),
                  (autoRedeemRetryAfter[snapshot.id] ?? .distantPast) <= date,
                  let claim = autoRedeemClaim(
                      for: snapshot,
                      preferences: preferences,
                      lastRedeemedWindowEnd: usageState.autoRedeemedWindowEnds[snapshot.id],
                      lastRedeemedExpiry: usageState.autoRedeemedExpiries[snapshot.id],
                      now: date
                  ) else {
                continue
            }
            let started = startResetRedeem(accountID: snapshot.id, condition: claim.condition) { [weak self] result in
                self?.finishAutoRedeem(claim, for: snapshot, result: result)
            }
            if started {
                setAutoRedeemGuard(claim.guardDate, for: claim.trigger, accountID: snapshot.id)
            }
        }
    }

    private func redeemSpentNothing(_ result: Result<RedeemedReset, Error>) -> Bool {
        switch result {
        case .success(let redeemed): return resetOutcomeSpentNothing(redeemed.outcome)
        case .failure(let error): return error is ResetNotAttempted
        }
    }

    private func finishAutoRedeem(_ claim: AutoRedeemClaim, for snapshot: AccountSnapshot, result: Result<RedeemedReset, Error>) {
        switch result {
        case .success(let redeemed):
            if redeemed.outcome == "reset" {
                notifyOrRecord(
                    key: "autoReset:\(claim.trigger.rawValue):\(snapshot.id)",
                    kind: .reset,
                    title: "Redeemed a reset for \(snapshot.name)",
                    detail: claim.detail,
                    at: Date()
                )
            }
            switch autoRedeemGuardUpdate(for: claim, redeemed: redeemed) {
            case .keep:
                break
            case .move(let spent):
                setAutoRedeemGuard(spent, for: claim.trigger, accountID: snapshot.id)
            case .release:
                releaseAutoRedeemGuard(for: claim, accountID: snapshot.id)
                autoRedeemRetryAfter[snapshot.id] = Date().addingTimeInterval(10 * 60)
            }
        case .failure(let error) where error is ResetNotAttempted:
            releaseAutoRedeemGuard(for: claim, accountID: snapshot.id)
        case .failure:
            break
        }
    }

    private func releaseAutoRedeemGuard(for claim: AutoRedeemClaim, accountID: String) {
        if let current = autoRedeemGuard(for: claim.trigger, accountID: accountID),
           abs(current.timeIntervalSince(claim.guardDate)) < 1 {
            setAutoRedeemGuard(nil, for: claim.trigger, accountID: accountID)
        }
    }

    private func autoRedeemGuard(for trigger: AutoRedeemClaim.Trigger, accountID: String) -> Date? {
        switch trigger {
        case .weekly: return usageState.autoRedeemedWindowEnds[accountID]
        case .expiry: return usageState.autoRedeemedExpiries[accountID]
        }
    }

    private func setAutoRedeemGuard(_ date: Date?, for trigger: AutoRedeemClaim.Trigger, accountID: String) {
        switch trigger {
        case .weekly: usageState.autoRedeemedWindowEnds[accountID] = date
        case .expiry: usageState.autoRedeemedExpiries[accountID] = date
        }
        StateLoader.save(usageState)
    }

    // Refreshes run every few minutes, which can land after a short expiry window has passed.
    private func scheduleExpiringResetCheck(for snapshots: [AccountSnapshot], after date: Date) {
        expiringResetTimer?.invalidate()
        expiringResetTimer = nil
        guard preferences.autoResetEnabled, let minutes = preferences.autoResetMinutesBeforeExpiry else {
            return
        }
        let nextCheck = snapshots
            .filter { canAutoRedeemReset($0.provider) && !$0.isError && $0.resetCreditsAvailable > 0 }
            .compactMap { $0.resetCreditExpiry?.addingTimeInterval(-TimeInterval(minutes * 60)) }
            .filter { $0 > date }
            .min()
        guard let nextCheck else {
            return
        }
        expiringResetTimer = Timer.scheduledTimer(withTimeInterval: nextCheck.timeIntervalSince(date), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.autoRedeemResets(in: self.snapshots, at: Date())
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

    private func refreshClaudeAfterReset() {
        for account in config?.accounts.filter({ $0.provider == .claudeCode }) ?? [] {
            usageState.apiLastCalledAt.removeValue(forKey: "\(Provider.claudeCode.rawValue):\(account.id)")
        }
        refreshOnceIdle()
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
        refreshOnceIdle()
    }

    private func refreshOnceIdle() {
        if isRefreshing {
            refreshAfterCurrent = true
            return
        }
        refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 0)
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
