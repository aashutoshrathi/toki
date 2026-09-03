import Foundation

/// The pin arithmetic the settings panel draws its chips from, kept out of private view
/// properties so it can be checked against what `menuBarEntries` actually draws.
struct MenuBarPinState: Equatable {
    /// Pinned and backed by a connected account, in pin order.
    let effective: [Provider]
    /// The tail the current density has no room for. Non-empty only after a density change
    /// shrank the cap under an existing selection, since adding past it is blocked.
    let overflow: [Provider]
    let cap: Int

    var drawn: [Provider] { Array(effective.prefix(cap)) }
    var canPinMore: Bool { effective.count < cap }
}

/// A pin with no connected account is skipped rather than counted: it never reaches the bar,
/// so letting it hold a slot would block one that would have.
func menuBarPinState(
    pinned: [Provider],
    connected: [Provider],
    density: MenuBarDensity
) -> MenuBarPinState {
    let connectedSet = Set(connected)
    let effective = pinned.filter(connectedSet.contains)
    return MenuBarPinState(
        effective: effective,
        overflow: Array(effective.dropFirst(density.maxSegments)),
        cap: density.maxSegments
    )
}

/// "Claude Code, Codex and Cursor" - for naming dropped pins inside a sentence.
func listedNames(_ providers: [Provider]) -> String {
    let names = providers.map(\.displayName)
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
}

/// Compact buys width by shrinking, so it spends the percent sign; Stacked has already halved
/// the readout by going vertical and keeps it. Cost readouts ("$12.30") are returned untouched.
func menuBarDisplayValue(_ value: String, density: MenuBarDensity) -> String {
    guard density == .compact, value.hasSuffix("%") else { return value }
    return String(value.dropLast())
}
