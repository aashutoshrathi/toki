import SwiftUI

// MARK: - StatBlock

struct StatBlock: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - ErrorBanner

struct ErrorBanner: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.red)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.red.opacity(0.22), lineWidth: 1))
            .fixedSize()
    }
}

// MARK: - ProviderPill

struct ProviderPill: View {
    var provider: Provider

    var body: some View {
        HStack(spacing: 5) {
            ProviderLogo(provider: provider, size: 11)
            Text(provider.displayName)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

// MARK: - MetricRow

struct MetricRow: View {
    var metric: MetricLine
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(metric.value)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                    .lineLimit(1)
                Text(copied ? "Copied" : metric.value)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help("Copy \(metric.label)")
        .pointerOnHover()
    }
}

// MARK: - QuotaSummaryLine

struct QuotaSummaryLine: View {
    var label: String
    var value: String
    var resetHint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                valueView
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let resetHint {
                Text(resetHint)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if let availability = availabilityPercent {
            HStack(spacing: 3) {
                Text("\(availability)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(availabilityColor(for: availability))
                Text("left")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var availabilityPercent: Int? {
        guard value.hasSuffix(" left"),
              let percentIndex = value.firstIndex(of: "%"),
              let percent = Int(value[..<percentIndex]) else {
            return nil
        }
        return percent
    }
}

// MARK: - AccountBadge

struct AccountBadge: View {
    var snapshot: AccountSnapshot
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let emoji = snapshot.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: size * 0.9))
            } else {
                ZStack {
                    if let color = colorFromHex(snapshot.colorHex) {
                        Circle()
                            .fill(color.opacity(0.18))
                            .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 1))
                    }
                    ProviderLogo(provider: snapshot.provider, size: size * 0.72)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
