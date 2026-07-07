import SwiftUI

struct MenuBarStatusView: View {
    var entries: [MenuBarStatusEntry]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    ProviderLogo(provider: entry.provider, size: 13)
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
