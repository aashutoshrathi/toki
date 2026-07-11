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
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
    }
}
