import SwiftUI

struct AccountCard: View {
    var snapshot: AccountSnapshot
    @ObservedObject var store: UsageStore
    var onExpand: (String) -> Void = { _ in }
    @ObservedObject var presentation: AccountPresentationState
    @State private var isEditingAlias = false
    @State private var aliasDraft = ""
    @FocusState private var aliasFocused: Bool
    @State private var confirmingReset = false
    @State private var isHovered = false

    init(snapshot: AccountSnapshot, store: UsageStore, presentation: AccountPresentationState,
         onExpand: @escaping (String) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.store = store
        self.presentation = presentation
        self.onExpand = onExpand
    }

    private var isExpanded: Bool {
        get { presentation.expandedAccountIDs.contains(snapshot.id) }
        nonmutating set {
            if newValue { presentation.expandedAccountIDs.insert(snapshot.id) }
            else { presentation.expandedAccountIDs.remove(snapshot.id) }
        }
    }

    private var expandedTab: AccountDetailTab {
        get { presentation.detailTab(for: snapshot) }
        nonmutating set { presentation.detailTabs[snapshot.id] = newValue }
    }

    // Active agents are discovered by scanning processes, which reveals the provider but not
    // which configured account authenticated them, so sessions are provider-scoped. The one
    // exception is Claude Code with multiple accounts: only one is active at a time (claude-swap),
    // and the active account is the one with no switch target, so sessions are attributed there
    // instead of double-counting on every Claude card.
    private var accountAgents: [ActiveAgent] {
        Self.attributedAgents(store.activeAgents, for: snapshot, among: store.snapshots)
    }

    static func attributedAgents(
        _ activeAgents: [ActiveAgent],
        for snapshot: AccountSnapshot,
        among snapshots: [AccountSnapshot]
    ) -> [ActiveAgent] {
        let agents = activeAgents.filter { $0.provider == snapshot.provider }
        guard snapshot.provider == .claudeCode else { return agents }
        let claudeSnapshots = snapshots.filter { $0.provider == .claudeCode }
        // Only narrow to the active account when the data unambiguously has one: exactly one
        // Claude account with no switch target. Zero or several would otherwise hide the session
        // everywhere or show it on multiple cards, so fall back to provider-scoped there.
        guard claudeSnapshots.count > 1,
              claudeSnapshots.filter({ $0.switchTarget == nil }).count == 1 else {
            return agents
        }
        return snapshot.switchTarget == nil ? agents : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse account" : "Show account details")
                .pointerOnHover()

                AccountBadge(snapshot: snapshot, size: 26)
                    .overlay(alignment: .topTrailing) {
                        if !accountAgents.isEmpty {
                            Text("\(accountAgents.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(Color.blue, in: Circle())
                                .offset(x: 4, y: -1)
                        }
                    }
                    // Opposite corner to the session count, so an account that is both busy
                    // and on a struggling provider still shows each signal in full.
                    .overlay(alignment: .bottomTrailing) {
                        if let serviceStatus {
                            ServiceStatusDot(level: serviceStatus.level)
                                .offset(x: 2, y: 1)
                                .help("\(serviceStatus.headline): \(serviceStatus.detail)")
                                .accessibilityLabel(serviceStatus.headline)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    aliasEditor

                    VStack(alignment: .leading, spacing: 1) {
                        // Provider name is omitted here - the account logo already conveys it.
                        if store.debugMode && snapshot.isError {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                        if let secondaryIdentifier {
                            Text(secondaryIdentifier)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                // Error text reads better cut from the end (keeps the
                                // meaningful lead-in); emails/org names keep .middle so the
                                // domain/tail stays visible instead of just the local part.
                                .truncationMode(snapshot.isError ? .tail : .middle)
                        }
                    }
                }

                Spacer(minLength: 8)

                collapsedSummary

                if let switchTarget = snapshot.switchTarget {
                    VStack(alignment: .trailing, spacing: 4) {
                        if snapshot.isError {
                            StatusBadge(text: snapshot.isSignInExpired ? "signed out" : "not connected")
                        }
                        Button {
                            store.switchClaudeAccount(target: switchTarget, command: snapshot.switchCommand)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Switch Claude Code to this account")
                        .accessibilityLabel("Switch Claude Code to this account")
                        .pointerOnHover()
                    }
                    .layoutPriority(1)
                }
            }

            if !quotaWindows.isEmpty {
                ForEach(quotaWindows) { window in
                    let paceHint = window.paceDeviation().map { $0 == 0 ? "On pace" : "\(abs($0))% \($0 > 0 ? "over" : "under") pace" }
                    usageBar(
                        period: window.label,
                        value: "\(window.percentLeft)% left",
                        ratio: Double(window.percentLeft) / 100,
                        resetHint: compactResetDescription(window.resetHint),
                        paceHint: paceHint,
                        paceRatio: window.expectedRemainingRatio()
                    )
                    .help([window.resetHint, paceHint].compactMap { $0 }.joined(separator: "\n"))
                }
            } else if let ratio = snapshot.displayProgressRatio {
                usageBar(
                    period: snapshot.menuBarValuePeriod ?? (snapshot.progressKind == .quota ? "Quota" : "Usage"),
                    value: "\(percentText(ratio)) \(snapshot.progressKind == .quota ? "left" : "used")",
                    ratio: ratio
                )
            }

            if isExpanded {
                Divider()
                    .padding(.top, 1)

                HStack(alignment: .center, spacing: 8) {
                    if snapshot.isError {
                        // The error itself, in full, rather than the word "Unavailable".
                        //
                        // That headline restated what the collapsed card already said with its
                        // "not connected" badge, and said it in the one place with room for the
                        // detail. Opening a card that is down is a request for the reason, so
                        // the reason is what goes here - wrapped rather than truncated, since a
                        // clipped error is no more useful than no error.
                        Text(errorDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    } else {
                        Text(snapshot.primary)
                            .font(TokiTypography.supporting)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer()
                        // Redundant with the header logo when the account is down anyway - only
                        // useful once the card's actually showing usage, to remind you which
                        // provider a custom alias maps to.
                        ProviderPill(provider: snapshot.provider)
                    }
                    accountActions
                }

                // The provider being down explains a stalled agent or a failing refresh, so it
                // sits above the metrics rather than under them.
                if let serviceStatus {
                    ServiceStatusRow(status: serviceStatus)
                }

                // Sessions only make sense for a connected account; when the account is
                // not connected, hide the toggle and just show usage (the error state).
                if !snapshot.isError && !snapshot.isAgentDetectionOnly {
                    Picker("Account detail", selection: Binding(get: { expandedTab }, set: { expandedTab = $0 })) {
                        ForEach(AccountDetailTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if snapshot.isError || (expandedTab == .usage && !snapshot.isAgentDetectionOnly) {
                    usageDetails
                } else {
                    accountSessions
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

                if snapshot.canAdjust && expandedTab == .usage {
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
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            if snapshot.isError {
                Capsule()
                    .fill(Color.red.opacity(0.75))
                    .frame(width: 2, height: 28)
                    .padding(.leading, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(
            TapGesture().onEnded {
                guard !isEditingAlias else { return }
                toggleExpanded()
            },
            including: .all
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .confirmationDialog("Spend a reset now?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Redeem reset", role: .destructive) {
                store.consumeCodexResetCredit(accountID: snapshot.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetWasteWarning)
        }
        .onChange(of: snapshot.isError) { _, isError in
            // Sessions has no meaning for a disconnected account; snap back to Usage so a
            // reconnect doesn't leave the toggle stuck on a hidden Sessions selection.
            if isError { expandedTab = .usage }
        }
    }

    private var accountActions: some View {
        Menu {
            Button("Rename", systemImage: "pencil") {
                aliasDraft = accountIdentifier
                isEditingAlias = true
                aliasFocused = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Account actions")
        .accessibilityLabel("Account actions")
    }

    @ViewBuilder
    private var usageDetails: some View {
        let rows = snapshot.isError ? snapshot.metrics.filter { $0.label != "Error" } : snapshot.metrics
        ForEach([MetricGroup.quota, .activity, .usage], id: \.self) { group in
            let metrics = rows.filter { $0.group == group }
            if !metrics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    ForEach(metrics) { metric in
                        MetricRow(metric: metric)
                    }
                }
                .font(TokiTypography.supporting)
                .padding(.vertical, 4)
            }
        }
        let details = snapshot.accountInfo + rows.filter { $0.group == .account }
        if !details.isEmpty {
            DisclosureGroup("Account details", isExpanded: Binding(
                get: { presentation.expandedAccountDetails.contains(snapshot.id) },
                set: { expanded in
                    if expanded { presentation.expandedAccountDetails.insert(snapshot.id) }
                    else { presentation.expandedAccountDetails.remove(snapshot.id) }
                }
            )) {
                VStack(spacing: 6) {
                    ForEach(details) { metric in
                        MetricRow(metric: maskedAccountInfo(metric))
                    }
                }
                .font(.system(size: 11))
                .padding(.top, 6)
            }
            .font(.system(size: 13, weight: .medium))
        }
    }

    private var resetCreditAction: some View {
        Button {
            confirmingReset = true
        } label: {
            HStack(spacing: 6) {
                if isResetting { ProgressView().controlSize(.small) }
                Label(isResetting ? "Resetting…" : resetButtonTitle, systemImage: "arrow.counterclockwise")
            }
        }
        .font(TokiTypography.supporting)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(isResetting)
        .accessibilityLabel("Reset quota, \(snapshot.resetCreditsAvailable) resets available")
        .help(resetButtonHelp)
        .pointerOnHover()
    }

    private var rowBackground: Color {
        if isExpanded { return Color.accentColor.opacity(0.075) }
        if snapshot.isError { return Color.red.opacity(0.035) }
        if isHovered { return Color.primary.opacity(0.035) }
        return .clear
    }

    @ViewBuilder
    private var aliasEditor: some View {
        HStack(spacing: 5) {
            if isEditingAlias {
                TextField("Alias", text: $aliasDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 120)
                    .focused($aliasFocused)
                    .onSubmit(saveAlias)
                Button {
                    saveAlias()
                } label: {
                    Image(systemName: "checkmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Save alias")
                .pointerOnHover()
            } else {
                Text(displayedAccountIdentifier)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

            }
        }
    }

    /// Set only while this account's provider reports trouble - an operational provider has
    /// nothing to add to a card that is already showing its quota.
    private var serviceStatus: ServiceStatus? {
        store.disruptedServiceStatus(for: snapshot.provider)
    }

    private var accountIdentifier: String {
        return snapshot.name
    }

    // Default Claude records repeat the email in both the generated name and the subtitle.
    // Keep custom nicknames intact, but let the secondary line carry the identity once when the
    // generated name exactly matches that default form.
    private var displayedAccountIdentifier: String {
        let displayName: String
        if snapshot.provider == .claudeCode,
           let email = emailAddress(in: snapshot),
           accountIdentifier == "Claude - \(email)" {
            displayName = snapshot.provider.displayName
        } else {
            displayName = accountIdentifier
        }
        return store.hidesSensitiveInfo ? SensitiveText.redactingEmails(displayName) : displayName
    }

    private var secondaryIdentifier: String? {
        let raw = emailAddress(in: snapshot) ?? (snapshot.subtitle.isEmpty ? nil : snapshot.subtitle)
        guard let raw else { return nil }
        return store.hidesSensitiveInfo ? SensitiveText.redactingEmails(raw) : raw
    }

    // Masks the value of an account-info row when it names something identifying (email, org),
    // so the expanded card is safe to screenshot with sensitive info hidden.
    private func maskedAccountInfo(_ metric: MetricLine) -> MetricLine {
        guard store.hidesSensitiveInfo else { return metric }
        switch metric.label {
        case "Email":
            var masked = metric
            masked.value = SensitiveText.redactingEmails(metric.value)
            return masked
        case "Org", "Org ID":
            var masked = metric
            masked.value = SensitiveText.redactedValue(metric.value)
            return masked
        default:
            return metric
        }
    }

    private var collapsedStatus: String {
        if snapshot.isSignInExpired { return snapshot.primary }
        return snapshot.isError ? "Not connected" : snapshot.primary
    }

    /// The failure reason, gathered from wherever the provider happened to record it.
    ///
    /// Claude Code puts it in an "Error" metric; the generic fetcher puts it in the subtitle.
    /// The subtitle is only usable when it isn't an email address, since Claude fills it with
    /// the account's address whenever it knows one.
    private var errorDetail: String {
        if let recorded = snapshot.metrics.first(where: { $0.label == "Error" || $0.label == "Sign-in" })?.value,
           !recorded.isEmpty {
            return recorded
        }
        if !snapshot.subtitle.isEmpty, !snapshot.subtitle.contains("@") {
            return snapshot.subtitle
        }
        return "Couldn't reach this account."
    }

    @ViewBuilder
    private var collapsedSummary: some View {
        if snapshot.isError && snapshot.switchTarget != nil {
            EmptyView()
        } else if snapshot.isError {
            Text(collapsedStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if snapshot.isAgentDetectionOnly {
            // No usage API to show a percentage for - the session count badge on the
            // account logo above already covers the live signal, so this just says
            // whether anything is running at all.
            Text(agentStatusActive ? "Active" : "Not running")
                .font(TokiTypography.supporting)
                .foregroundStyle(agentStatusActive ? Color.blue : Color.secondary)
        } else if snapshot.provider == .codex, snapshot.resetCreditsAvailable > 0 {
            resetCreditAction
        } else if snapshot.remainingRatio == nil {
            // The source supplies the reporting period; compact costs may describe a
            // billing cycle even when another provider reports today's spend.
            VStack(alignment: .trailing, spacing: 2) {
                if let bar = snapshot.menuBarValue {
                    Text(bar)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                    if let period = snapshot.menuBarValuePeriod {
                        Text(period)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let todayMetric = snapshot.metrics.first(where: { $0.label == "Today" }) {
                    Text(todayMetric.value)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func usageBar(
        period: String, value: String, ratio: Double,
        resetHint: String? = nil, paceHint: String? = nil, paceRatio: Double? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(period)
                if let resetHint {
                    Text(resetHint).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(TokiTypography.supporting)
            .foregroundStyle(.secondary)
            ProgressView(value: min(1, max(0, ratio)))
                .tint(progressTint(ratio))
                .scaleEffect(y: 0.65, anchor: .center)
                .frame(height: 4)
                .overlay {
                    if let paceRatio {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(.primary.opacity(0.8))
                                .frame(width: 2, height: 10)
                                .position(
                                    x: min(geometry.size.width - 1, max(1, geometry.size.width * paceRatio)),
                                    y: geometry.size.height / 2
                                )
                        }
                        .allowsHitTesting(false)
                    }
                }
            if let paceHint {
                Text(paceHint)
                    .font(TokiTypography.supporting)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(period)
        .accessibilityValue([value, resetHint, paceHint?.replacingOccurrences(of: "% ", with: " percentage points ")].compactMap { $0 }.joined(separator: ". "))
    }

    private var quotaWindows: [RateLimitWindow] {
        [snapshot.primaryWindow, snapshot.secondaryWindow].compactMap { $0 }
    }

    @ViewBuilder
    private var accountSessions: some View {
        if accountAgents.isEmpty {
            Text("No active \(snapshot.provider.displayName) sessions")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("All active \(snapshot.provider.displayName) sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                ForEach(accountAgents) { agent in
                    let identity = SessionIdentityPresentation(agent: agent, among: store.activeAgents)
                    Button {
                        ActiveAgentNavigator.navigate(to: agent)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(identity.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if let context = identity.context {
                                    Text(context)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                Text(identity.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: agent.hasTerminalTarget ? "arrow.up.forward.app" : "macwindow.on.rectangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.blue)
                                .frame(width: 28, height: 28)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help("Open " + identity.title)
                    .pointerOnHover()
                }
            }
        }
    }

    private var isResetting: Bool {
        store.resettingAccountIDs.contains(snapshot.id)
    }

    private var resetButtonTitle: String {
        snapshot.resetCreditsAvailable > 1 ? "\(snapshot.resetCreditsAvailable) resets" : "1 reset"
    }

    private var resetButtonHelp: String {
        var help = "Redeem a banked reset credit to reset this rate limit window now"
        if let expiry = snapshot.resetCreditExpiry {
            help += ". Expires \(resetDescription(for: expiry))."
        }
        return help
    }

    // A reset is a limited, banked resource: redeeming while quota remains discards the rest
    // of the current window. State how much is still left so the confirmation is an informed
    // choice rather than a bare warning. Also surface the credit's expiry when known, so the
    // user can decide whether to redeem now or wait (issue #130).
    private var resetWasteWarning: String {
        let leftRatio = snapshot.remainingRatio ?? snapshot.progressRatio.map { 1 - $0 }
        if let percentLeft = leftRatio.map({ Int(($0 * 100).rounded()) }) {
            var warning = "You still have \(percentLeft)% of this window left. A reset is a limited banked credit, and redeeming it now discards that remaining quota."
            if let expiry = snapshot.resetCreditExpiry {
                warning += " This reset credit expires \(resetDescription(for: expiry))."
            }
            return warning + " Redeem anyway?"
        }
        var warning = "A reset is a limited banked credit and redeeming it now discards the quota you haven't used yet."
        if let expiry = snapshot.resetCreditExpiry {
            warning += " This reset credit expires \(resetDescription(for: expiry))."
        }
        return warning + " Redeem anyway?"
    }

    private var statusColor: Color {
        if snapshot.isError { return .red }
        guard let remaining = snapshot.remainingRatio else { return .secondary }
        if remaining <= 0.15 { return .red }
        if remaining <= 0.40 { return .orange }
        return .green
    }

    private func progressTint(_ ratio: Double) -> Color {
        let used = snapshot.progressKind == .quota ? 1 - ratio : ratio
        if used >= 0.85 { return .red }
        if used >= 0.60 { return .orange }
        return .green
    }

    private func saveAlias() {
        store.renameAccount(snapshot: snapshot, alias: aliasDraft)
        isEditingAlias = false
    }

    private var agentStatusActive: Bool {
        if !accountAgents.isEmpty { return true }
        if let last = snapshot.lastActivity { return Date().timeIntervalSince(last) < 300 }
        return false
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
