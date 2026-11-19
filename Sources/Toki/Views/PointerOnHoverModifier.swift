import SwiftUI

struct PointerOnHoverModifier: ViewModifier {
    var isEnabled: Bool = true
    @State private var isPushed: Bool = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && isEnabled {
                    if !isPushed {
                        NSCursor.pointingHand.push()
                        isPushed = true
                    }
                } else {
                    if isPushed {
                        NSCursor.pop()
                        isPushed = false
                    }
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled && isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

extension View {
    func pointerOnHover(_ enabled: Bool = true) -> some View {
        modifier(PointerOnHoverModifier(isEnabled: enabled))
    }
}
