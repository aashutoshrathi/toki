import SwiftUI

struct AccountCard: View {
    var snapshot: AccountSnapshot
    @ObservedObject var store: UsageStore
    var onExpand: (String) -> Void = { _ in }
    @State private var isExpanded = false
    @State private var isEditingAlias = false
    @State private var aliasDraft = ""
    @State private var expandedTab: ExpandedTab = .usage
    @State private var showRemoveConfirmation = false

    private enum ExpandedTab: String, CaseIterable, Identifiable {
        case usage = "Usage"
        case sessions = "Sessions"
        var id: String { rawValue }
    }

    // Active agents are discovered by scanning processes, which reveals the provider but not
    // which configured account authenticated them. So sessions are provider-scoped: every card
    // for a given provider surfaces the same list. The UI copy makes that scope explicit.
    private var accountAgents: [ActiveAgent] {
        store.activeAgents.filter { $0.provider == snapshot.provider }
    }

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
                        // Provider name is omitted here - the account logo already conveys it.
                        if store.debugMode && snapshot.isError {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
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

                // Sessions only make sense for a connected account; when the account is
                // not connected, hide the toggle and just show usage (the error state).
                if !snapshot.isError {
                    Picker("", selection: $expandedTab) {
                        ForEach(ExpandedTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if snapshot.isError || expandedTab == .usage {
                    if !snapshot.metrics.isEmpty {
                        VStack(spacing: 3) {
                            ForEach(snapshot.metrics) { metric in
                                MetricRow(metric: metric)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                } else {
                    accountSessions
                }

                if expandedTab == .usage && !snapshot.accountInfo.isEmpty {
                    Divider()
                        .padding(.vertical, 1)
                    VStack(spacing: 3) {
                        ForEach(snapshot.accountInfo) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }

                if snapshot.resetCreditsAvailable > 0 {
                    HStack(spacing: 8) {
                        Button {
                            store.consumeCodexResetCredit(accountID: snapshot.id)
                        } label: {
                            if isResetting {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Resetting Codex rate limit")
                            } else {
                                Label(resetButtonTitle, systemImage: "arrow.counterclockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isResetting || !canUseResetCredit)
                        .help(resetButtonHelp)
                        .pointerOnHover()
                        Spacer()
                    }
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

                Divider()
                    .padding(.top, 1)

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Label("Remove account", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .help("Remove this account from Toki")
                    .pointerOnHover()
                }
                .confirmationDialog(
                    "Remove \(snapshot.name)?",
                    isPresented: $showRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        store.removeAccount(accountID: snapshot.id)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This only removes it from Toki's config - it doesn't sign you out or affect the account itself. You can add it back later.")
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
        .onChange(of: snapshot.isError) { _, isError in
            // Sessions has no meaning for a disconnected account; snap back to Usage so a
            // reconnect doesn't leave the toggle stuck on a hidden Sessions selection.
            if isError { expandedTab = .usage }
        }
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
        } else if snapshot.provider == .codex, !codexWindows.isEmpty {
            // Codex carries two independent quota windows (5h + weekly) instead of Claude's
            // single rolling one, so it gets its own summary instead of the generic fallback
            // to a raw token count below - shows just one line when only one window is available.
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(codexWindows) { window in
                    QuotaSummaryLine(label: window.label, value: "\(window.percentLeft)% left", resetHint: window.resetHint)
                }
            }
        } else {
            QuotaSummaryLine(label: "current", value: currentSessionAvailability, resetHint: currentResetTime)
        }
    }

    private var codexWindows: [RateLimitWindow] {
        [snapshot.primaryWindow, snapshot.secondaryWindow].compactMap { $0 }
    }

    private var currentSessionAvailability: String {
        availabilityText(for: ["Daily", "5h", "Today"]) ?? snapshot.primary
    }

    @ViewBuilder
    private var accountSessions: some View {
        if accountAgents.isEmpty {
            Text("No active \(snapshot.provider.displayName) sessions")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("All active \(snapshot.provider.displayName) sessions")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach(accountAgents) { agent in
                    Button {
                        ActiveAgentNavigator.navigate(to: agent)
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                if let dir = agent.directoryDisplay {
                                    Text(dir)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            if let host = agent.hostApp {
                                Text(host.displayName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Image(systemName: agent.hasTerminalTarget ? "arrow.up.forward.app" : "macwindow.on.rectangle")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                }
            }
        }
    }

    private func availabilityText(for labels: Set<String>) -> String? {
        guard let metric = snapshot.metrics.first(where: { labels.contains($0.label) }) else {
            return nil
        }
        return remainingText(from: metric.value)
    }

    private var currentResetTime: String? {
        guard let metric = snapshot.metrics.first(where: { ["Daily", "5h", "Today"].contains($0.label) }),
              let range = metric.value.range(of: "resets in ") else {
            return nil
        }
        return String(metric.value[range.lowerBound...])
    }


    private var progressRatio: Double? {
        snapshot.progressRatio ?? snapshot.remainingRatio.map { 1 - $0 }
    }

    private var isResetting: Bool {
        store.resettingAccountIDs.contains(snapshot.id)
    }

    // Resets are a limited, banked resource - redeeming one while plenty of quota remains
    // just throws it away. Only allow it once the window is mostly spent. Uses the same
    // progressRatio (used fraction) the progress bar renders, so it works whether the
    // snapshot populated progressRatio or only remainingRatio.
    private var canUseResetCredit: Bool {
        guard let progressRatio else { return false }
        return progressRatio >= 0.80
    }

    private var resetButtonTitle: String {
        snapshot.resetCreditsAvailable > 1 ? "Reset now (\(snapshot.resetCreditsAvailable) available)" : "Reset now"
    }

    private var resetButtonHelp: String {
        if canUseResetCredit {
            return "Redeem a banked reset credit to reset this rate limit window now"
        }
        if progressRatio == nil {
            return "Current usage is unavailable, so Toki can't confirm this reset would be worth spending"
        }
        return "Save this reset for when you're closer to the limit (usage must be at least 80% used)"
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
