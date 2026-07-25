import SwiftUI

struct QuotaRingsPanel: View {
    let snapshots: [AccountSnapshot]
    @State private var hoveredSnapshotID: String?

    var body: some View {
        QuotaRingsView(
            snapshots: ringSnapshots,
            size: 124,
            hoveredSnapshotID: $hoveredSnapshotID
        )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let hoveredSnapshot {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ringColor(hoveredSnapshot))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hoveredSnapshot.provider.displayName)
                                .font(.system(size: 10, weight: .semibold))
                            Text(percentText(hoveredSnapshot.remainingRatio ?? 0))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 1))
                    .padding(7)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoveredSnapshotID)
            .padding(.vertical, 12)
            .background(
                RadialGradient(
                    colors: [panelAccent.opacity(0.11), Color.primary.opacity(0.035)],
                    center: .center,
                    startRadius: 8,
                    endRadius: 180
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.085), lineWidth: 1)
            }
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

    private var hoveredSnapshot: AccountSnapshot? {
        ringSnapshots.first { $0.id == hoveredSnapshotID }
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

            Group {
                if let centerProvider {
                    ProviderLogo(provider: centerProvider, size: centerBadgeSize * 0.6)
                } else {
                    TokiLogoMark(size: centerBadgeSize * 0.56)
                }
            }
                .frame(width: centerBadgeSize, height: centerBadgeSize)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
                .allowsHitTesting(false)
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
        (snapshots.first { $0.id == hoveredSnapshotID } ?? snapshots.first)?.provider
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
