import SwiftUI

struct PointerOnHoverModifier: ViewModifier {
    var isEnabled: Bool = true

    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard isEnabled else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointerOnHover(_ enabled: Bool = true) -> some View {
        modifier(PointerOnHoverModifier(isEnabled: enabled))
    }
}
