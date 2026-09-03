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
                DetailCard(
                    snapshot: hovered.snapshot,
                    tailCentre: geometry.rowCentreY(hovered.index) - frame.minY
                )
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
        let rows = [snapshot.primaryWindow, snapshot.secondaryWindow].compactMap { $0 }.count + snapshot.modelWindows.count
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
        .background(Color.black, in: RailShape())
        .contentShape(RailShape())
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
                isHighlighted: hoveredID == snapshot.id,
                seatsGlyph: true
            )
            Text(snapshot.remainingRatio.map { percentText($0) } ?? "--")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
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
    /// Where the tail meets the card, measured from its top.
    let tailCentre: CGFloat

    private var windows: [RateLimitWindow] {
        let reported = [snapshot.primaryWindow, snapshot.secondaryWindow].compactMap { $0 } + snapshot.modelWindows
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
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Near-solid: at 0.92 whatever sits behind the card reads through it, and the card is
        // mostly small text over an arbitrary desktop.
        .background(
            Color.black.opacity(0.97),
            in: CardWithTailShape(tailCentre: tailCentre)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
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

/// The rail's silhouette, as the concept draws it: flush to the display's right edge, flaring
/// out of the menu bar with an inverted corner rather than meeting it at a right angle, and
/// rounded where it hangs free.
///
/// The top-left corner is concave - a quarter disc taken out at the corner - which is the same
/// join macOS uses where the notch meets the band. A square corner there reads as a panel
/// sitting under the menu bar; this reads as the menu bar itself growing downward.
struct RailShape: Shape {
    var flare: CGFloat = 10
    var bottomRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + flare, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.minX, y: rect.minY),
            radius: flare,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The hover card's outline, with a tail on its right edge aimed at the ring being hovered.
/// `tailCentre` is measured from the card's own top, so a card pushed away from centre to stay
/// on screen still points at the right row.
struct CardWithTailShape: Shape {
    var cornerRadius: CGFloat = 12
    var tailCentre: CGFloat
    var tailHeight: CGFloat = 16
    var tailDepth: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: 0, dy: 0).divided(atDistance: rect.width - tailDepth, from: .minXEdge).slice
        var path = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)

        let top = min(max(tailCentre - tailHeight / 2, cornerRadius), rect.maxY - cornerRadius - tailHeight)
        var tail = Path()
        tail.move(to: CGPoint(x: body.maxX - 1, y: top))
        tail.addLine(to: CGPoint(x: rect.maxX, y: top + tailHeight / 2))
        tail.addLine(to: CGPoint(x: body.maxX - 1, y: top + tailHeight))
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}
