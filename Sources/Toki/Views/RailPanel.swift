import SwiftUI

/// The vertical rail: one ring per provider down the screen edge, with a detail card on hover.
///
/// Pinned dark like the notch panel. It hangs off the menu bar band and reads as an extension
/// of it, which only works if it stays the same colour whatever the desktop behind it is doing.
struct RailPanel: View {
    let snapshots: [AccountSnapshot]
    let geometry: RailGeometry
    let hoveredID: String?
    let onHover: (String?) -> Void
    let onClick: () -> Void

    private var drawn: [AccountSnapshot] { Array(snapshots.prefix(geometry.drawnCount)) }

    private var hovered: (index: Int, snapshot: AccountSnapshot)? {
        guard let hoveredID,
              let index = drawn.firstIndex(where: { $0.id == hoveredID }) else { return nil }
        return (index, drawn[index])
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            rail
                .frame(width: geometry.rail.width, height: geometry.rail.height, alignment: .top)
                .offset(x: geometry.rail.minX, y: geometry.rail.minY)

            if let hovered {
                let frame = geometry.card(forRow: hovered.index, height: cardHeight(for: hovered.snapshot))
                DetailCard(snapshot: hovered.snapshot)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.12), value: hoveredID)
    }

    // Two rows plus the title, or one row for a provider with a single window.
    private func cardHeight(for snapshot: AccountSnapshot) -> CGFloat {
        let rows = [snapshot.primaryWindow, snapshot.secondaryWindow].compactMap { $0 }.count
        return 34 + CGFloat(max(rows, 1)) * 32
    }

    private var rail: some View {
        VStack(spacing: RailGeometry.rowSpacing) {
            ForEach(drawn) { snapshot in
                row(snapshot)
            }
            if geometry.overflowCount > 0 {
                overflowRow
            }
        }
        .padding(RailGeometry.railPadding)
        .frame(width: geometry.rail.width, height: geometry.rail.height, alignment: .top)
        .background(Color.black, in: BottomRoundedShape(cornerRadius: 12))
        .contentShape(BottomRoundedShape(cornerRadius: 12))
        .onTapGesture(perform: onClick)
        .pointerOnHover()
    }

    private func row(_ snapshot: AccountSnapshot) -> some View {
        VStack(spacing: 1) {
            RingGauge(
                provider: snapshot.provider,
                remainingRatio: snapshot.remainingRatio,
                color: ringColor(snapshot),
                diameter: RailGeometry.ringDiameter,
                isHighlighted: hoveredID == snapshot.id
            )
            Text(snapshot.remainingRatio.map { percentText($0) } ?? "--")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(height: RailGeometry.rowHeight)
        .contentShape(Rectangle())
        .onHover { onHover($0 ? snapshot.id : nil) }
        .accessibilityLabel("\(snapshot.name), \(snapshot.remainingRatio.map { percentText($0) } ?? "unknown") left")
    }

    private var overflowRow: some View {
        Text("+\(geometry.overflowCount)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .frame(height: RailGeometry.rowHeight)
            .accessibilityLabel("\(geometry.overflowCount) more account\(geometry.overflowCount == 1 ? "" : "s"), open Toki to see them")
    }
}

/// The hover detail: every quota window the provider reports, each with a bar, a percentage and
/// when it resets.
private struct DetailCard: View {
    let snapshot: AccountSnapshot

    private var windows: [RateLimitWindow] {
        let reported = [snapshot.primaryWindow, snapshot.secondaryWindow].compactMap { $0 }
        guard reported.isEmpty else { return reported }
        // Providers with a single overall percentage and no named windows still deserve a card.
        return [RateLimitWindow(
            label: "Remaining",
            percentLeft: Int(((snapshot.remainingRatio ?? 0) * 100).rounded()),
            resetHint: nil
        )]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderLogo(provider: snapshot.provider, size: 12)
                Text(snapshot.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            ForEach(windows) { window in
                windowRow(window)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Near-solid: at 0.92 whatever sits behind the card reads through it, and the card is
        // mostly small text over an arbitrary desktop.
        .background(Color.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func windowRow(_ window: RateLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 4)
                Text("\(window.percentLeft)% left")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(ringColor(snapshot))
                        .frame(width: proxy.size.width * min(1, max(0, Double(window.percentLeft) / 100)))
                }
            }
            .frame(height: 4)
            if let resetHint = window.resetHint {
                Text(resetHint)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }
}
