import SwiftUI

struct AccountCard: View {
    var snapshot: AccountSnapshot
    @ObservedObject var store: UsageStore
    var onExpand: (String) -> Void = { _ in }
    @State private var isExpanded = false
    @State private var isEditingAlias = false
    @State private var aliasDraft = ""

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

                if !snapshot.metrics.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(snapshot.metrics) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }

                if !snapshot.accountInfo.isEmpty {
                    Divider()
                        .padding(.vertical, 1)
                    VStack(spacing: 3) {
                        ForEach(snapshot.accountInfo) { metric in
                            MetricRow(metric: metric)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
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
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                QuotaSummaryLine(label: "current", value: currentSessionAvailability, resetHint: currentResetTime)
                QuotaSummaryLine(label: "weekly", value: weeklyAvailability, resetHint: weeklyResetTime)
            }
        }
    }

    private var currentSessionAvailability: String {
        availabilityText(for: ["Daily", "5h", "Today"]) ?? snapshot.primary
    }

    private var weeklyAvailability: String {
        availabilityText(for: ["7d", "Weekly", "Week"]) ?? "--"
    }

    private func availabilityText(for labels: Set<String>) -> String? {
        guard let metric = snapshot.metrics.first(where: { labels.contains($0.label) }) else {
            return nil
        }
        return remainingText(from: metric.value)
    }

    private var currentResetTime: String? {
        if let resetMetric = snapshot.metrics.first(where: { $0.label == "Reset" }) {
            return resetMetric.value
        }
        if let metric = snapshot.metrics.first(where: { ["Daily", "5h", "Today"].contains($0.label) }),
           let range = metric.value.range(of: "resets ") {
            return String(metric.value[range.upperBound...])
        }
        return nil
    }

    private var weeklyResetTime: String? {
        if let metric = snapshot.metrics.first(where: { ["7d", "Weekly", "Week"].contains($0.label) }),
           let range = metric.value.range(of: "resets ") {
            return String(metric.value[range.upperBound...])
        }
        return nil
    }

    private var progressRatio: Double? {
        snapshot.progressRatio ?? snapshot.remainingRatio.map { 1 - $0 }
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
