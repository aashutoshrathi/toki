import AppKit
import SwiftUI

struct QuotaRingsPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshots: [AccountSnapshot]
    var onHide: () -> Void = {}
    @State private var hoveredSnapshotID: String?

    var body: some View {
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
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 6) {
                    ForEach(ringSnapshots) { snapshot in
                        card(snapshot)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                QuotaRingsView(
                    snapshots: ringSnapshots,
                    colors: ringColors,
                    size: 88,
                    hoveredSnapshotID: $hoveredSnapshotID
                )
                .padding(.trailing, 4)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 12)
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
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Hide the quota rings — turn them back on in Settings")
        .accessibilityLabel("Hide quota rings")
        .pointerOnHover()
    }

    private func card(_ snapshot: AccountSnapshot) -> some View {
        let isHovered = hoveredSnapshotID == snapshot.id
        let color = color(for: snapshot)
        return HStack(spacing: 8) {
            ProviderLogo(provider: snapshot.provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(chipTitle(for: snapshot))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(percentText(snapshot.remainingRatio ?? 0)) left")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if let resetHint = snapshot.primaryWindow?.resetHint {
                    Text(resetHint)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isHovered ? color.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        var seen = Set<String>()
        return snapshots.filter {
            !$0.isError
                && !$0.isLoadingPlaceholder
                && $0.remainingRatio != nil
                && seen.insert($0.id).inserted
        }
    }

    private func chipTitle(for snapshot: AccountSnapshot) -> String {
        let alias = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameProviderCount = ringSnapshots.filter { $0.provider == snapshot.provider }.count
        if sameProviderCount > 1, !alias.isEmpty {
            return alias
        }
        return snapshot.provider.displayName
    }

    private var ringColors: [String: Color] {
        var result: [String: Color] = [:]
        let groups = Dictionary(grouping: ringSnapshots, by: { $0.provider })
        for (_, group) in groups {
            for (index, snap) in group.enumerated() {
                if let custom = colorFromHex(snap.colorHex) {
                    result[snap.id] = custom
                } else if group.count == 1 {
                    result[snap.id] = ringColor(snap)
                } else {
                    result[snap.id] = shaded(ringColor(snap), index: index, count: group.count)
                }
            }
        }
        return result
    }

    private func color(for snapshot: AccountSnapshot) -> Color {
        ringColors[snapshot.id] ?? ringColor(snapshot)
    }

    private func shaded(_ base: Color, index: Int, count: Int) -> Color {
        let ns = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
        let t = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let factor = colorScheme == .dark ? 1 + t * 0.32 : 0.72 + t * 0.28
        return Color(
            red: min(1, Double(ns.redComponent) * factor),
            green: min(1, Double(ns.greenComponent) * factor),
            blue: min(1, Double(ns.blueComponent) * factor)
        )
    }
}

private struct QuotaRingsView: View {
    let snapshots: [AccountSnapshot]
    let colors: [String: Color]
    let size: CGFloat
    @Binding var hoveredSnapshotID: String?

    var body: some View {
        ZStack {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                let diameter = size - CGFloat(index) * ringSpacing * 2
                let color = colors[snapshot.id] ?? ringColor(snapshot)

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
                    .background(.fill.tertiary, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            snapshots
                .map { snap in
                    let alias = snap.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = alias.isEmpty ? snap.provider.displayName : alias
                    return "\(label), \(percentText(snap.remainingRatio ?? 0)) remaining"
                }
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
