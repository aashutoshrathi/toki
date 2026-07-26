import SwiftUI

public enum GlassStyle {
    public static let cornerRadius: CGFloat = 8
    public static let tintOpacity: Double = 0.18
    public static let prominentByDefault = false

    @available(macOS 26, *)
    public static func resolve(prominent: Bool, tint: Color?, tintOpacity: Double, interactive: Bool) -> Glass {
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
