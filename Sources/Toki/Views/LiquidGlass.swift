import SwiftUI

extension View {
    @ViewBuilder
    func glassSurface<Fill: ShapeStyle>(
        cornerRadius: CGFloat = 8,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackFill: Fill,
        fallbackStroke: Color? = nil,
        fallbackStrokeOpacity: Double = 1,
        fallbackStrokeWidth: CGFloat = 1
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            let base = interactive ? Glass.regular.interactive() : Glass.regular
            let glass = tint.map { base.tint($0.opacity(0.45)) } ?? base
            glassEffect(glass, in: shape)
        } else {
            background(fallbackFill, in: shape)
                .overlay(shape.strokeBorder(
                    (fallbackStroke ?? .clear).opacity(fallbackStroke == nil ? 0 : fallbackStrokeOpacity),
                    lineWidth: fallbackStroke == nil ? 0 : fallbackStrokeWidth
                ))
        }
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
