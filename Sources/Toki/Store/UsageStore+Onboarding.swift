import Foundation

extension UsageStore {
    // True when there's nothing to lose by showing the connect wizard: no config.json yet,
    // or one that decodes fine but simply has no accounts. A config.json that exists and
    // decodes but is invalid for any other reason (e.g. a copilot entry) - or doesn't decode
    // at all - is a real error; connect() would still fail its own validate() call there, so
    // showing Connect buttons would be a dead end. Those cases fall through to the normal
    // error banner instead (config stays nil, needsOnboarding is false).
    //
    // Computed once per reloadConfig() and cached in the stored property above rather than
    // recomputed as a view-body computed property - it does synchronous disk I/O + JSON
    // decoding, which shouldn't run on every SwiftUI re-render.
    private func computeNeedsOnboarding() -> Bool {
        guard FileManager.default.fileExists(atPath: ConfigLoader.path) else { return true }
        return ConfigLoader.loadRawIfParsable()?.accounts.isEmpty ?? false
    }

    func reloadConfig() {
        do {
            config = try ConfigLoader.load()
            setNeedsOnboarding(false)
            usageState = StateLoader.load()
            syncPublishedState()
            applyScheduledResets()
            configError = nil
            snapshots = config?.accounts.map(AccountSnapshot.loading) ?? []
            updateDerivedState(for: snapshots)
            scheduleRefresh()
            refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "config", code: "load_failed", detail: diagnosticErrorDetail(error))
            config = nil
            let needsOnboarding = computeNeedsOnboarding()
            setNeedsOnboarding(needsOnboarding)
            snapshots = []
            updateDerivedState(for: snapshots)
            // The onboarding state (missing/empty config) is expected, not an error - don't
            // show a scary "Missing config" message for it. Genuinely broken configs still do.
            if needsOnboarding {
                configError = nil
                scanForOnboarding()
            } else {
                configError = error.localizedDescription
            }
        }
    }

    // Re-probes for newly installed/authenticated CLIs while the onboarding screen is
    // showing, so e.g. signing into Codex after Toki launched doesn't require a restart.
    // Called each time the popover opens; a no-op once a config exists (use
    // rescanProviders() to scan unconditionally, e.g. for the "Add account" page).
    func rescanProvidersIfNeeded() {
        guard needsOnboarding else { return }
        scanForOnboarding()
    }

    // Same probe, but runs regardless of needsOnboarding - for the "Add account" page,
    // which stays reachable after the first account is connected (someone might start
    // with just Claude and add Codex later without hand-editing config.json).
    func rescanProviders() {
        scanForOnboarding()
    }

    // detectedProviders minus anything already present in snapshots (whether connected
    // through config.json or auto-detected like OpenCode) - what's left to offer, whether
    // this is first-run onboarding (snapshots is always empty there, so this is just
    // detectedProviders) or the "Add account" page reached after accounts already exist.
    var addableProviders: [DetectedProvider] {
        detectedProviders.filter { detected in !snapshots.contains(where: { $0.provider == detected.provider }) }
    }

    // Probes for installed/authenticated CLIs (Claude Code, Codex, OpenCode, Grok) so
    // the onboarding/add-account screens can offer them as one-click connects.
    private func scanForOnboarding() {
        guard !isScanningProviders else { return }
        isScanningProviders = true
        Task {
            detectedProviders = await ProviderDetection.scan()
            isScanningProviders = false
        }
    }

    // Appends detected accounts to config.json (creating it if this is a fresh install)
    // and reloads. Accounts already present for the same provider+id are skipped.
    //
    // config is nil for ANY load failure, including the exact onboarding case of a file
    // that decodes fine but has no accounts yet - that's safe to build on top of via
    // loadRawIfParsable(). A file that exists but doesn't decode at all must not be
    // silently replaced with a blank one (data loss), so that case alone is refused.
    func connect(_ accounts: [AccountConfig]) {
        var next: AppConfig
        if let config {
            next = config
        } else if let parsed = ConfigLoader.loadRawIfParsable() {
            next = parsed
        } else if !FileManager.default.fileExists(atPath: ConfigLoader.path) {
            next = AppConfig(refreshMinutes: nil, accountLabels: nil, accounts: [], aiInstructions: nil)
        } else {
            configError = "\(ConfigLoader.path) exists but couldn't be parsed - fix or replace it with the config editor before connecting."
            return
        }
        // Dedupe on bare id, not provider+id: ConfigLoader.validate() now requires ids to
        // be unique across the whole config, not just per provider, so skipping only
        // provider+id matches here could still append an id that's already taken under a
        // different provider (e.g. a manual account someone happened to id "codex") and
        // fail validate() below - turning a working connect into an opaque error.
        var existingIDs = Set(next.accounts.map(\.id))
        for account in accounts {
            guard !existingIDs.contains(account.id) else { continue }
            next.accounts.append(account)
            existingIDs.insert(account.id)
        }
        do {
            try ConfigLoader.validate(next)
            try ConfigLoader.save(next)
            reloadConfig()
        } catch {
            DiagnosticLogger.shared.record(.error, component: "config", code: "connect_failed", detail: diagnosticErrorDetail(error))
            configError = "Could not connect account: \(error.localizedDescription)"
        }
    }

    func applyScheduledResets() {
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
