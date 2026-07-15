import SwiftUI

struct MenuBarStatusView: View {
    var entries: [MenuBarStatusEntry]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    if let leadingText = entry.leadingText {
                        Text(leadingText)
                            .font(.system(size: 12, weight: .regular))
                    } else {
                        ProviderLogo(provider: entry.provider, size: 13)
                    }
                    Text(entry.value)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        // Fixed width regardless of digit count (e.g. "5%" vs "100%") so the
                        // status item's overall fitting size - and therefore its position in
                        // the menu bar and the popover anchored to it - doesn't shift on every
                        // refresh as the percentage ticks up or down.
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
    }
}
