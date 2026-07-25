import SwiftUI

extension View {
    @ViewBuilder
    func glassSurface<Fill: ShapeStyle>(
        cornerRadius: CGFloat = 8,
        tint: Color? = nil,
        fallbackFill: Fill,
        fallbackStroke: Color? = nil,
        fallbackStrokeOpacity: Double = 1,
        fallbackStrokeWidth: CGFloat = 1
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            if let tint {
                glassEffect(.regular.tint(tint.opacity(0.45)), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
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
