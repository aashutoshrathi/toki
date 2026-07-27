import SwiftUI

extension View {
    /// Keeps data and settings in the content layer instead of competing with the popover's
    /// system-provided material. A semantic fill adapts to appearance and accessibility settings;
    /// the optional stroke is reserved for states that need an explicit boundary.
    func contentSurface(cornerRadius: CGFloat = 8, stroke: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.fill.tertiary, in: shape)
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke.opacity(0.22), lineWidth: 1)
                }
            }
    }

    /// Reserves Liquid Glass for the app's persistent functional layer. Data remains on
    /// standard content materials so the toolbar reads as controls floating above information,
    /// and the system can adapt the glass for contrast, transparency, and window focus.
    @ViewBuilder
    func functionalGlass(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
