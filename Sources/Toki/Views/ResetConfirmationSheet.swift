import SwiftUI

struct ResetConfirmationSheet: View {
    var snapshot: AccountSnapshot
    var selectedGroup: ResetCreditGroup? = nil
    var onConfirm: (_ targetGrantID: String?) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var activeGrant: ResetGrantItem? {
        if let selectedGroup {
            let targetID = selectedGroup.grantID ?? selectedGroup.id
            if let match = snapshot.allResetGrants.first(where: { $0.id == targetID }) {
                return match
            }
        }
        return snapshot.allResetGrants.first(where: { $0.isNext }) ?? snapshot.allResetGrants.first
    }

    private var upcomingGrants: [ResetGrantItem] {
        guard let active = activeGrant else { return [] }
        var list: [ResetGrantItem] = []
        if active.count > 1 {
            var remaining = active
            remaining.count = active.count - 1
            remaining.isNext = false
            list.append(remaining)
        }
        for item in snapshot.allResetGrants where item.id != active.id {
            var queued = item
            queued.isNext = false
            list.append(queued)
        }
        return list
    }

    private var targetGrantID: String? {
        if let grantID = selectedGroup?.grantID {
            return grantID
        }
        if let active = activeGrant {
            return active.id
        }
        return snapshot.resetCreditGroups.first(where: { $0.canRedeemNow })?.grantID
    }

    private struct QuotaWarning {
        var isExhausted: Bool
        var message: String
    }

    private var quotaWarning: QuotaWarning {
        let isFable = selectedGroup?.kind == .fable || activeGrant?.kind == .fable
        let creditName = isFable ? "Fable reset" : "reset"

        if isFable {
            let fableWindow = snapshot.modelWindows.first { $0.label.lowercased().contains("fable") }
            if let fableWindow {
                if fableWindow.percentLeft <= 0 {
                    return QuotaWarning(
                        isExhausted: true,
                        message: "Your Fable quota is currently exhausted. Redeeming a \(creditName) will restore your quota immediately."
                    )
                }
                return QuotaWarning(
                    isExhausted: false,
                    message: "You still have \(fableWindow.percentLeft)% of this Fable window left. Redeeming a \(creditName) now will discard that remaining quota."
                )
            }
        }

        let fiveHour = snapshot.allWindows.first { $0.label.contains("5h") || $0.label.contains("Daily") }
        let sevenDay = snapshot.allWindows.first { $0.label.contains("7d") || $0.label.contains("Weekly") }

        if let fiveHour, let sevenDay {
            if fiveHour.percentLeft <= 0 && sevenDay.percentLeft <= 0 {
                return QuotaWarning(
                    isExhausted: true,
                    message: "Your rate limit quota is currently exhausted. Redeeming a \(creditName) will restore your quota immediately."
                )
            }
            var parts: [String] = []
            if fiveHour.percentLeft > 0 {
                parts.append("\(fiveHour.percentLeft)% of 5h window")
            }
            if sevenDay.percentLeft > 0 {
                parts.append("\(sevenDay.percentLeft)% of weekly window")
            }
            let remainingText = parts.isEmpty ? "quota" : parts.joined(separator: " and ")
            return QuotaWarning(
                isExhausted: false,
                message: "You still have \(remainingText) left. Redeeming a \(creditName) now will discard that remaining quota."
            )
        }

        let leftRatio = snapshot.remainingRatio ?? snapshot.progressRatio.map { 1 - $0 }
        if let percentLeft = leftRatio.map({ Int(($0 * 100).rounded()) }) {
            if percentLeft <= 0 {
                return QuotaWarning(
                    isExhausted: true,
                    message: "Your rate limit quota is currently exhausted. Redeeming a \(creditName) will restore your quota immediately."
                )
            }
            return QuotaWarning(
                isExhausted: false,
                message: "You still have \(percentLeft)% of this window left. Redeeming a \(creditName) now will discard that remaining quota."
            )
        }

        return QuotaWarning(
            isExhausted: false,
            message: "Redeeming a \(creditName) now will discard any quota remaining in your current rate limit window."
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerView

            warningCallout

            if let active = activeGrant {
                activeGrantCard(active)
            }

            upcomingGrantsSection

            Divider()

            footerActions
        }
        .padding(18)
        .frame(width: 375)
    }

    private var headerView: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(quotaWarning.isExhausted ? Color.accentColor : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Redeem Rate Limit Reset")
                    .font(.headline)

                Text(snapshot.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var warningCallout: some View {
        let warning = quotaWarning
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: warning.isExhausted ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(warning.isExhausted ? Color.accentColor : Color.orange)
                .padding(.top, 1)

            Text(warning.message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (warning.isExhausted ? Color.accentColor : Color.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((warning.isExhausted ? Color.accentColor : Color.orange).opacity(0.25), lineWidth: 1)
        )
    }

    private func activeGrantCard(_ grant: ResetGrantItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REDEEMING NOW")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("1 credit")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                Image(systemName: grant.kind == .fable ? "sparkles" : "bolt.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(grant.kind == .fable ? Color.purple : Color.accentColor)

                Text(grant.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Spacer()
            }

            HStack(spacing: 12) {
                Label {
                    Text("Clears: \(grant.clearsDescription)")
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                if let expiry = grant.expiry {
                    Label {
                        Text("Expires \(resetDescription(for: expiry))")
                            .font(.system(size: 10.5))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        )
    }

    private var upcomingGrantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NEXT IN QUEUE")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !upcomingGrants.isEmpty {
                    let totalUpcoming = upcomingGrants.reduce(0) { $0 + $1.count }
                    Text("\(totalUpcoming) upcoming")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            if upcomingGrants.isEmpty {
                HStack {
                    Spacer()
                    Text("No further reset credits queued.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                tableOfUpcomingGrants
            }
        }
    }

    private var tableOfUpcomingGrants: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Credit")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Clears")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 82, alignment: .leading)

                Text("Status")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 76, alignment: .leading)

                Text("Expires")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(upcomingGrants) { grant in
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Text(grant.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                if grant.count > 1 {
                                    Text("×\(grant.count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(grant.clearsDescription)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 82, alignment: .leading)

                            statusPill(for: grant)
                                .frame(width: 76, alignment: .leading)

                            Text(expiryText(for: grant.expiry))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func statusPill(for grant: ResetGrantItem) -> some View {
        let needsLimit = grant.requiresLimit && !grant.atLimit
        let text = needsLimit ? "Needs limit" : "Queued"
        return Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                needsLimit ? Color.orange.opacity(0.14) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            )
            .foregroundStyle(needsLimit ? Color.orange : Color.secondary)
    }

    private func expiryText(for date: Date?) -> String {
        guard let date else { return "Never" }
        return resetDescription(for: date)
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Redeem reset") {
                let id = targetGrantID
                onConfirm(id)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(quotaWarning.isExhausted ? Color.accentColor : Color.red)
            .keyboardShortcut(.defaultAction)
        }
    }
}
