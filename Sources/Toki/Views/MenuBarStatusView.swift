import SwiftUI

struct MenuBarStatusView: View {
    var entries: [MenuBarStatusEntry]
    // Number of agent sessions parked waiting on the user. Zero hides the badge entirely.
    var awaitingInput: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            if awaitingInput > 0 {
                attentionBadge
            }
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

    // A filled dot carrying the count of sessions waiting on you.
    //
    // The digit is punched out of the dot rather than drawn in a colour: the menu bar is dark
    // in full screen even under a light system appearance, so any fixed foreground colour is
    // wrong half the time. Knocking the glyph out with destinationOut lets the bar itself show
    // through, which stays legible on every background - the same reasoning that keeps the
    // status text on `.primary` instead of a pinned appearance.
    private var attentionBadge: some View {
        Text("\(awaitingInput)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .blendMode(.destinationOut)
            .padding(2)
            .frame(minWidth: 14, minHeight: 14)
            .background(Color.primary, in: Circle())
            .compositingGroup()
            .accessibilityLabel("\(awaitingInput) agent\(awaitingInput == 1 ? "" : "s") waiting for input")
    }
}
