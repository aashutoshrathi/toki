import SwiftUI

// Reachable any time from the header "+" button, not just on the zero-account onboarding
// screen - someone might start with just Claude and want to add Codex later without
// hand-editing config.json. Reuses OnboardingView as-is; it already filters to accounts
// not yet present (see UsageStore.addableProviders), so already-connected providers don't
// show a redundant Connect button here.
struct AddAccountPage: View {
    @ObservedObject var store: UsageStore
    var onClose: () -> Void
    var openConfigEditor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 25, height: 25)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
                .pointerOnHover()
                Text("Add account")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            OnboardingView(store: store, openConfigEditor: openConfigEditor)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            store.rescanProviders()
        }
    }
}
