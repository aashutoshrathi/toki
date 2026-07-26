import SwiftUI

enum GlassStyle {
    static let cornerRadius: CGFloat = 8
    static let tintOpacity: Double = 0.18
    static let prominentByDefault = false

    @available(macOS 26, *)
    static func resolve(prominent: Bool, tint: Color?, tintOpacity: Double, interactive: Bool) -> Glass {
        var glass = prominent ? Glass.regular : Glass.clear
        if let tint {
            glass = glass.tint(tint.opacity(tintOpacity))
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

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
