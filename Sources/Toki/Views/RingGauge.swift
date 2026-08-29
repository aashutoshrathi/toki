import SwiftUI

/// A single provider's remaining quota as a ring, with its mark in the middle.
///
/// Toki shows what is left rather than what is used, everywhere. The concept this came from
/// printed "73% Used"; flipping the meaning for one surface would make the rail disagree with
/// every other number in the app.
struct RingGauge: View {
    let provider: Provider
    let remainingRatio: Double?
    let color: Color
    var diameter: CGFloat = 26
    var isHighlighted: Bool = false

    private var lineWidth: CGFloat { max(diameter * 0.13, 3) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            if let remainingRatio {
                Circle()
                    .trim(from: 0, to: min(1, max(0, remainingRatio)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            ProviderLogo(provider: provider, size: diameter * 0.42)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(isHighlighted ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }
}
