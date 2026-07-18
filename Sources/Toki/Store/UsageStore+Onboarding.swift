import Foundation

enum ProviderScanDisposition: Equatable {
    case persistConnectable
    case activateLocalUsage
    case noAction
}

func providerScanDisposition(
    detected: [DetectedProvider],
    snapshotProviders: Set<Provider>,
    configIsNil: Bool,
    needsOnboarding: Bool
) -> ProviderScanDisposition {
    let newProviders = detected.filter { !snapshotProviders.contains($0.provider) }
    if newProviders.contains(where: \.isConnectable) { return .persistConnectable }
    if configIsNil, needsOnboarding, newProviders.contains(where: { !$0.isConnectable }) {
        return .activateLocalUsage
    }
    return .noAction
}

extension UsageStore {
    // True when there's nothing to lose by showing the connect wizard: no config.json yet,
    // or one that decodes fine but simply has no accounts. A config.json that exists and
    // decodes but is invalid for any other reason (e.g. duplicate account ids) - or doesn't decode
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
                rescanProviders()
            } else {
                configError = error.localizedDescription
            }
        }
    }

    // Re-probes for newly installed/authenticated CLIs every time the popover opens, so
    // e.g. signing into Codex - or connecting Grok for the first time - after Toki
    // launched doesn't require a restart. Runs regardless of needsOnboarding: someone
    // might start with just Claude and pick up Codex, Grok, etc. later. Anything
    // detected that's connectable gets added automatically (see connectDetected) -
    // there's no separate manual "Add account" step to trigger it.
    func rescanProviders() {
        guard !isScanningProviders else { return }
        isScanningProviders = true
        Task {
            let detected = await ProviderDetection.scan()
            detectedProviders = detected
            isScanningProviders = false
            connectDetected(detected)
        }
    }

    // detectedProviders minus anything already present in snapshots (whether connected
    // through config.json or auto-detected like OpenCode) - only ever non-empty for a
    // moment between a scan finding something and connectDetected writing it, or for
    // local-only providers with no makeAccount that never get written at all.
    var addableProviders: [DetectedProvider] {
        detectedProviders.filter { detected in !snapshots.contains(where: { $0.provider == detected.provider }) }
    }

    // Auto-adds newly detected connectable providers. On a fresh install with only
    // local-history providers, installs an empty config in memory so UsageFetcher can
    // surface its synthetic accounts without creating config.json on disk.
    private func connectDetected(_ detected: [DetectedProvider]) {
        let snapshotProviders = Set(snapshots.map(\.provider))
        switch providerScanDisposition(
            detected: detected,
            snapshotProviders: snapshotProviders,
            configIsNil: config == nil,
            needsOnboarding: needsOnboarding
        ) {
        case .persistConnectable:
            let newAccounts = detected.compactMap { candidate -> AccountConfig? in
                guard candidate.isConnectable, !snapshotProviders.contains(candidate.provider) else { return nil }
                return candidate.makeAccount?()
            }
            guard !newAccounts.isEmpty else { return }
            connect(newAccounts)
        case .activateLocalUsage:
            config = AppConfig(refreshMinutes: nil, accountLabels: nil, accounts: [], aiInstructions: nil)
            setNeedsOnboarding(false)
            configError = nil
            // Match the successful config-load path before refresh can persist state;
            // otherwise a configless local-only launch would overwrite saved user state
            // with the UsageStore initializer's defaults.
            usageState = StateLoader.load()
            syncPublishedState()
            scheduleRefresh()
            refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
        case .noAction:
            return
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
