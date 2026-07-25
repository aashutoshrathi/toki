import SwiftUI

struct QuotaRingsPanel: View {
    let snapshots: [AccountSnapshot]
    var onHide: () -> Void = {}
    @State private var hoveredSnapshotID: String?

    var body: some View {
        // A header row ("QUOTA" left, Hide right) keeps those two clear of the ring below, so
        // nothing crowds. Cards and ring sit in the row underneath and are vertically centered,
        // so the card's height follows its content instead of a fixed, oversized ring.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Quota")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                hideButton
            }

            // Cards fill the available width instead of a fixed 150; the HStack spacing keeps a
            // comfortable gap to the ring so the wider cards never feel crowded against it.
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    ForEach(ringSnapshots) { snapshot in
                        card(snapshot)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                QuotaRingsView(
                    snapshots: ringSnapshots,
                    size: 84,
                    hoveredSnapshotID: $hoveredSnapshotID
                )
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassSurface(
            cornerRadius: 11,
            tint: panelAccent,
            fallbackFill: RadialGradient(
                colors: [panelAccent.opacity(0.11), Color.primary.opacity(0.035)],
                center: .trailing,
                startRadius: 8,
                endRadius: 220
            ),
            fallbackStroke: .primary,
            fallbackStrokeOpacity: 0.085
        )
        .animation(.easeOut(duration: 0.12), value: hoveredSnapshotID)
    }

    private var hideButton: some View {
        Button(action: onHide) {
            HStack(spacing: 3) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text("Hide")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Hide the quota rings — turn them back on in Settings")
        .accessibilityLabel("Hide quota rings")
        .pointerOnHover()
    }

    private func card(_ snapshot: AccountSnapshot) -> some View {
        let isHovered = hoveredSnapshotID == snapshot.id
        let color = ringColor(snapshot)
        return HStack(spacing: 8) {
            ProviderLogo(provider: snapshot.provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(percentText(snapshot.remainingRatio ?? 0)) left")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if let resetHint = snapshot.primaryWindow?.resetHint {
                    Text(resetHint)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isHovered ? color.opacity(0.18) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovered ? color.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            if hovering {
                hoveredSnapshotID = snapshot.id
            } else if hoveredSnapshotID == snapshot.id {
                hoveredSnapshotID = nil
            }
        }
        .pointerOnHover()
    }

    private var ringSnapshots: [AccountSnapshot] {
        var seen = Set<Provider>()
        return snapshots.filter {
            !$0.isError
                && !$0.isLoadingPlaceholder
                && $0.remainingRatio != nil
                && seen.insert($0.provider).inserted
        }
    }

    private var panelAccent: Color {
        ringSnapshots.first.map(ringColor) ?? .accentColor
    }
}

private struct QuotaRingsView: View {
    let snapshots: [AccountSnapshot]
    let size: CGFloat
    @Binding var hoveredSnapshotID: String?

    var body: some View {
        ZStack {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                let diameter = size - CGFloat(index) * ringSpacing * 2
                let color = ringColor(snapshot)

                ZStack {
                    Circle()
                        .stroke(color.opacity(0.16), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, snapshot.remainingRatio ?? 0)))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                    .onHover { isHovered in
                        if isHovered {
                            hoveredSnapshotID = snapshot.id
                        } else if hoveredSnapshotID == snapshot.id {
                            hoveredSnapshotID = nil
                        }
                    }
                    .pointerOnHover()
            }

            if let centerProvider {
                ProviderLogo(provider: centerProvider, size: centerBadgeSize * 0.6)
                    .frame(width: centerBadgeSize, height: centerBadgeSize)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            snapshots
                .map { "\($0.provider.displayName), \(percentText($0.remainingRatio ?? 0)) remaining" }
                .joined(separator: "; ")
        )
    }

    private var centerProvider: Provider? {
        snapshots.first { $0.id == hoveredSnapshotID }?.provider
    }

    private var lineWidth: CGFloat {
        size / (CGFloat(max(snapshots.count, 1)) * 5)
    }

    private var ringSpacing: CGFloat { lineWidth * 1.75 }

    private var centerBadgeSize: CGFloat {
        let innermostDiameter = size - CGFloat(max(snapshots.count - 1, 0)) * ringSpacing * 2
        return max(26, min(42, innermostDiameter - lineWidth * 2 - 8))
    }
}

private func ringColor(_ snapshot: AccountSnapshot) -> Color {
    switch snapshot.provider {
    case .claude, .claudeCode, .anthropic:
        return Color(red: 0.85, green: 0.47, blue: 0.34)
    case .codex, .openai, .chatgpt:
        return Color(red: 0.48, green: 0.61, blue: 1)
    case .openCode:
        return Color(red: 0.20, green: 0.72, blue: 0.48)
    case .gemini:
        return Color(red: 0.66, green: 0.33, blue: 0.97)
    case .copilot:
        return Color(red: 0.55, green: 0.45, blue: 0.95)
    case .pi:
        return Color(red: 0.94, green: 0.36, blue: 0.55)
    case .grok:
        return Color(red: 0.66, green: 0.68, blue: 0.72)
    default:
        return Color(red: 0.93, green: 0.39, blue: 0.58)
    }
}
