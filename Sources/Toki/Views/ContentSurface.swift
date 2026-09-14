import SwiftUI

enum TokiTypography {
    static let body = Font.system(size: 13)
    static let supporting = Font.system(size: 11)
    static let heading = Font.system(size: 15, weight: .semibold)
}

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
    func functionalGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    @ViewBuilder
    func functionalControlStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .controlSize(.large)
        } else {
            buttonStyle(FunctionalControlButtonStyle())
        }
    }
}

struct FunctionalControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .frame(width: 28, height: 28)
            .contentShape(shape)
            .functionalGlass(in: shape, interactive: true)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.4)
    }
}
