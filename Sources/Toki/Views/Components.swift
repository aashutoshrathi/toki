import AppKit
import SwiftUI

// MARK: - UpdateAvailableBanner

// Shared with Settings' "Check now" button so both places offer the same install/dismiss
// affordance instead of Settings only reporting a status string.
struct UpdateAvailableBanner: View {
    var update: AvailableUpdate
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(update.isPrerelease ? "Toki \(update.version) beta is available" : "Toki \(update.version) is available",
                  systemImage: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Button("What's New") { updateChecker.openRelease() }
                    .buttonStyle(.bordered)
                Button(updateChecker.isInstalling ? "Installing…" : "Update") { updateChecker.installUpdate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(updateChecker.isInstalling)
                if updateChecker.isInstalling { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Menu {
                    Button("Remind me in 6 hours") { updateChecker.snooze() }
                    Button("Skip \(update.version)") { updateChecker.dismiss() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Snooze or skip update")
            }
            .controlSize(.small)
            if let error = updateChecker.installError {
                DisclosureGroup("Update couldn't be installed") {
                    Text(error).textSelection(.enabled)
                }
                .font(TokiTypography.supporting)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .contentSurface(stroke: .blue)
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
        .contentSurface()
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

    private var canExpand: Bool { !suggestions.isEmpty || summary.count > 110 }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 6 : 0) {
            HStack(alignment: .center, spacing: 6) {
                Button {
                    if canExpand { expanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Group {
                            if isUpdating {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: isAI ? "sparkles" : "lightbulb")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isAI ? .purple : .secondary)
                            }
                        }
                        .frame(width: 11, height: 11)
                        Text(summary)
                            .font(TokiTypography.supporting)
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if canExpand {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityValue(canExpand ? (expanded ? "Expanded" : "Collapsed") : "")
                .pointerOnHover()

                if let switchAction {
                    Button(action: switchAction.perform) {
                        Label("Switch", systemImage: switchAction.systemImage)
                            .font(TokiTypography.supporting)
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(switchAction.help)
                    .accessibilityLabel(switchAction.help)
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
                            .font(TokiTypography.supporting)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentSurface()
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
                    .frame(minWidth: 75, idealWidth: 90, alignment: .leading)
                    .lineLimit(1)
                Text(copied ? "Copied" : metric.value)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(TokiTypography.supporting)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(metric.label)")
        .pointerOnHover()
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

// MARK: - Service status

extension ServiceStatusLevel {
    var tint: Color {
        switch self {
        case .operational: return .green
        case .maintenance: return .blue
        // The app's severity palette is green/orange/red, with no yellow anywhere else: orange
        // reads as slow, red as down, and the wording carries the rest.
        case .degraded: return .orange
        case .partialOutage: return .red
        case .majorOutage: return .red
        }
    }
}

/// The dot that rides on an account's logo while its provider reports trouble.
///
/// Drawn with a ring in the card's own background colour so it stays legible against the logo
/// it overlaps, the way a badge does.
struct ServiceStatusDot: View {
    var level: ServiceStatusLevel
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(level.tint)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }
}

/// The expanded card's line about the provider being down, with a way to go read the detail.
struct ServiceStatusRow: View {
    var status: ServiceStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ServiceStatusDot(level: status.level, size: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 1) {
                Text(status.headline)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.level.tint)
                Text(status.detail)
                    .font(TokiTypography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                NSWorkspace.shared.open(status.pageURL)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(status.pageURL.host ?? "the provider status page")")
            .accessibilityLabel("Open the provider status page")
            .pointerOnHover()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(status.level.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(TokiTypography.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .contentSurface()
    }
}
