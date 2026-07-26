import SwiftUI
import TokiWidgetShared

extension View {
    @ViewBuilder
    func glassSurface<Fill: ShapeStyle>(
        cornerRadius: CGFloat = GlassStyle.cornerRadius,
        tint: Color? = nil,
        tintOpacity: Double = GlassStyle.tintOpacity,
        prominent: Bool = GlassStyle.prominentByDefault,
        interactive: Bool = false,
        fallbackFill: Fill,
        fallbackStroke: Color? = nil,
        fallbackStrokeOpacity: Double = 1,
        fallbackStrokeWidth: CGFloat = 1
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(
                GlassStyle.resolve(prominent: prominent, tint: tint, tintOpacity: tintOpacity, interactive: interactive),
                in: shape
            )
        } else {
            background(fallbackFill, in: shape)
                .overlay {
                    if let fallbackStroke {
                        shape.strokeBorder(fallbackStroke.opacity(fallbackStrokeOpacity), lineWidth: fallbackStrokeWidth)
                    }
                }
        }
    }
}
