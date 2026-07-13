import SwiftUI

struct EventPanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.setDND(!store.preferences.dndEnabled)
                } label: {
                    Label(store.preferences.dndEnabled ? "DND On" : "DND Off", systemImage: store.preferences.dndEnabled ? "moon.zzz.fill" : "bell")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Toggle do not disturb")
                .pointerOnHover()

                Spacer()

                Button {
                    store.clearEvents()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .frame(width: 25, height: 25)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("Clear event history")
                .accessibilityLabel("Clear event history")
                .pointerOnHover()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.events.isEmpty {
                        EmptyPanel(systemImage: "bell.badge", title: "No events yet", detail: "Low quota, session, switch, and notification events appear here.")
                    } else {
                        ForEach(store.events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: event))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(color(for: event))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(event.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        if event.deliveredNotification {
                                            Image(systemName: "bell.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.blue)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    Text(event.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
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
        }
        .frame(maxHeight: accountListHeight())
    }

    private func icon(for event: TokiEvent) -> String {
        switch event.kind {
        case .lowQuota: return "exclamationmark.triangle.fill"
        case .recovered: return "checkmark.circle.fill"
        case .switchAccount: return "arrow.triangle.2.circlepath"
        case .session: return "timer"
        case .notification: return event.deliveredNotification ? "bell.fill" : "bell.slash"
        case .refresh: return "arrow.clockwise"
        }
    }

    private func color(for event: TokiEvent) -> Color {
        switch event.kind {
        case .lowQuota: return .orange
        case .recovered: return .green
        case .switchAccount: return .blue
        case .session: return .purple
        case .notification: return event.deliveredNotification ? .blue : .secondary
        case .refresh: return .secondary
        }
    }
}
