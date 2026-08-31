import Foundation

/// What the settings panel needs in order to draw the pin chips honestly.
///
/// The panel makes three claims at once - how many pins fit, which ones are reaching the menu
/// bar, and which are pinned but being dropped - and all three have to agree with what
/// `menuBarEntries` actually draws. Keeping the arithmetic here rather than in private view
/// properties is what lets that agreement be tested.
struct MenuBarPinState: Equatable {
    /// Pins that could reach the bar: pinned and backed by a connected account, in pin order.
    let effective: [Provider]
    /// The tail of `effective` that the current density has no room for. Only ever non-empty
    /// after a density change shrank the cap underneath an existing selection, since the panel
    /// blocks adding past it.
    let overflow: [Provider]
    let cap: Int

    /// Pins that actually reach the bar, which is what `menuBarEntries` will draw.
    var drawn: [Provider] { Array(effective.prefix(cap)) }

    /// False once the cap is reached, which is when the panel stops accepting new pins rather
    /// than accepting one that then quietly never appears.
    var canPinMore: Bool { effective.count < cap }
}

/// A pin whose provider has no connected account is skipped rather than counted: it never
/// reaches the bar, so letting it use up a slot would block a pin that would have.
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

/// "Claude Code", "Claude Code and Codex", "Claude Code, Codex and Cursor" - for naming the
/// pins a density is dropping, in a sentence rather than as a bare list.
func listedNames(_ providers: [Provider]) -> String {
    let names = providers.map(\.displayName)
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
}

/// The percent sign is the one character in a readout carrying no information the glyph beside
/// it doesn't already imply, so Compact - whose whole job is width - spends it on something
/// else. Stacked has already halved the readout by going vertical and keeps it. Cost readouts
/// ("$12.30") have no percent sign and are returned untouched.
func menuBarDisplayValue(_ value: String, density: MenuBarDensity) -> String {
    guard density == .compact, value.hasSuffix("%") else { return value }
    return String(value.dropLast())
}
