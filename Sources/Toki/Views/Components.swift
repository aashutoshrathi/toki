import SwiftUI

// MARK: - UpdateAvailableBanner

// Shared with Settings' "Check now" button so both places offer the same install/dismiss
// affordance instead of Settings only reporting a status string.
struct UpdateAvailableBanner: View {
    var update: AvailableUpdate
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Toki \(update.version) is available")
                        .font(.system(size: 11, weight: .semibold))
                    Text(updateChecker.isInstalling ? "Downloading and verifying update…" : "Install the latest GitHub release.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    updateChecker.installUpdate()
                } label: {
                    if updateChecker.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(updateChecker.isInstalling)

                Button {
                    updateChecker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss this version")
                .accessibilityLabel("Dismiss update notification")
            }

            if let error = updateChecker.installError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - StatBlock

struct StatBlockAction {
    var systemImage: String
    var help: String
    var perform: () -> Void
}

struct StatBlock: View {
    var title: String
    var value: String
    var systemImage: String
    var action: StatBlockAction?

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
            if let action {
                Button(action: action.perform) {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(action.help)
                .accessibilityLabel(action.help)
                .pointerOnHover()
            }
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

// MARK: - SessionRecordingCard

// Thin banner shown while a tracking session is active, with a live-ticking stopwatch.
struct SessionRecordingCard: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 7) {
                Image(systemName: "record.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                Text("Recording token usage for this session")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(formatDuration(seconds: context.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

// MARK: - AIInsightCard

// The compact overview. Shows a one-line summary (AI-generated when available, else the
// deterministic recommendation) and reveals suggestions on tap. An optional switch action
// carries over the one-click "switch to best account" that used to live in the stat cards.
struct AIInsightCard: View {
    var summary: String
    var suggestions: [UsageSuggestion]
    var isAI: Bool
    var isUpdating: Bool = false
    var switchAction: StatBlockAction?

    @State private var expanded = false

    private var canExpand: Bool { !suggestions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 6 : 0) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    if canExpand { expanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: isAI ? "sparkles" : "lightbulb")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isAI ? .purple : .secondary)
                        }
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if canExpand {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointerOnHover()

                Spacer(minLength: 4)

                if let switchAction {
                    Button(action: switchAction.perform) {
                        Image(systemName: switchAction.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(switchAction.help)
                    .pointerOnHover()
                }
            }

            if expanded {
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(color(for: suggestion.severity))
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        Text(suggestion.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background((isAI ? Color.purple : Color.primary).opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((isAI ? Color.purple : Color.primary).opacity(isAI ? 0.18 : 0.08), lineWidth: 1)
        )
    }

    private func color(for severity: RecommendationSeverity) -> Color {
        switch severity {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .neutral: return .secondary
        }
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

// MARK: - EmptyPanel

struct EmptyPanel: View {
    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}
