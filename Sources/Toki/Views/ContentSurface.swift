import SwiftUI

extension View {
    func contentSurface(cornerRadius: CGFloat = 8, stroke: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.fill.tertiary, in: shape)
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke.opacity(0.22), lineWidth: 1)
                }
            }
    }

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
