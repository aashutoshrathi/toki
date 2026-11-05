import SwiftUI

// A provider with more than one signed-in account collapses to a single card so the accounts
// read as one thing instead of N near-identical rows. Collapsed, it shows a bar divided into
// one segment per account; expanded, each account becomes its own full AccountCard with the
// quota bars, pace markers, resets and sessions it would have had on its own.
struct AccountGroupCard: View {
    var snapshots: [AccountSnapshot]
    @ObservedObject var store: UsageStore
    var onExpand: (String) -> Void = { _ in }
    @State private var isExpanded = false
    @State private var isHovered = false

    private var provider: Provider { snapshots[0].provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                Divider()
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshots) { snapshot in
                        AccountCard(snapshot: snapshot, store: store, onExpand: onExpand)
                            .id(snapshot.id)
                    }
                }
            } else {
                stackedBar
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            if snapshots.contains(where: \.isError) {
                Capsule()
                    .fill(Color.red.opacity(0.75))
                    .frame(width: 2, height: 28)
                    .padding(.leading, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse accounts" : "Show \(snapshots.count) accounts")
            .pointerOnHover()

            AccountBadge(snapshot: snapshots[0], size: 26)
                .overlay(alignment: .topTrailing) {
                    if !sessionCount.isEmpty {
                        Text("\(sessionCount.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(2)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Color.blue, in: Circle())
                            .offset(x: 4, y: -1)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(snapshots.count) accounts")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let lowest = lowestPercentLeft {
                Text("Lowest \(lowest)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(healthColor(lowest))
            } else if snapshots.contains(where: \.isError) {
                Text("Unavailable")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var lowestPercentLeft: Int? {
        snapshots.compactMap { $0.remainingRatio.map { Int(($0 * 100).rounded()) } }.min()
    }

    private var sessionCount: [ActiveAgent] {
        store.activeAgents.filter { $0.provider == provider }
    }

    private var rowBackground: Color {
        if isExpanded { return Color.accentColor.opacity(0.075) }
        if snapshots.contains(where: \.isError) { return Color.red.opacity(0.035) }
        if isHovered { return Color.primary.opacity(0.035) }
        return .clear
    }

    private struct Segment: Identifiable {
        let id: String
        let name: String
        let percentLeft: Int?
        let fillRatio: Double?
        let color: Color
    }

    private var segments: [Segment] {
        snapshots.map { snapshot in
            let percent = snapshot.remainingRatio.map { Int(($0 * 100).rounded()) }
            return Segment(
                id: snapshot.id,
                name: snapshot.name,
                percentLeft: percent,
                fillRatio: snapshot.remainingRatio.map { min(1, max(0, $0)) },
                color: healthColor(percent)
            )
        }
    }

    private var stackedBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(segments) { segment in
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            if let ratio = segment.fillRatio {
                                Capsule()
                                    .fill(segment.color)
                                    .frame(width: geometry.size.width * ratio)
                            }
                        }
                    }
                    .frame(height: 6)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 7, height: 7)
                        Text(segment.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(segment.percentLeft.map { "\($0)% left" } ?? "—")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(segment.color)
                    }
                }
            }
        }
        .help("Each segment is one account; the fill is how much quota that account has left.")
    }

    private func healthColor(_ percentLeft: Int?) -> Color {
        guard let percentLeft else { return .secondary }
        if percentLeft <= 15 { return .red }
        if percentLeft <= 40 { return .orange }
        return .green
    }
}
