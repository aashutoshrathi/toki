import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.history.isEmpty {
                    EmptyPanel(systemImage: "chart.line.uptrend.xyaxis", title: "No history yet", detail: "Toki records local quota snapshots after refreshes.")
                } else {
                    ForEach(store.history.prefix(80)) { entry in
                        HStack(alignment: .center, spacing: 8) {
                            ProviderLogo(provider: entry.provider, size: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.accountName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.remainingRatio.map(percentText) ?? "--")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(entry.remainingRatio.map(historyColor) ?? .secondary)
                                Text(entry.primary)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.trailing, 2)
        }
        .frame(maxHeight: accountListHeight())
    }

    private func historyColor(_ ratio: Double) -> Color {
        if ratio <= 0.15 { return .red }
        if ratio <= 0.40 { return .orange }
        return .primary
    }
}
