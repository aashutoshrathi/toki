import SwiftUI

struct MenuBarStatusView: View {
    var entries: [MenuBarStatusEntry]
    var awaitingInput: Int = 0
    var remoteControlOn: Bool = false
    var density: MenuBarDensity = .comfortable

    var body: some View {
        HStack(spacing: metrics.groupSpacing) {
            if awaitingInput > 0 {
                attentionBadge
            }
            if remoteControlOn {
                Image(systemName: "arcade.stick")
                    .font(.system(size: metrics.glyphSize, weight: .bold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Remote Control is on")
            }
            if entries.isEmpty {
                tokiMark
            } else if density == .stacked {
                stackedEntries
            } else {
                ForEach(entries) { entry in
                    segment(for: entry)
                }
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(height: 22)
    }

    // The same mark the panel header draws, minus its glass tile, so the menu bar and the
    // panel show one logo rather than two versions of it.
    //
    // It is an app-icon canvas: the artwork covers a little over half the square, with the
    // rest transparent padding meant to sit inside a squircle. Drawn at icon size that
    // padding is most of what you get, and the mark reads as a speck beside the system's own
    // status icons. So it is drawn oversized and cropped back to the icon box, which throws
    // away the margin instead of the detail.
    private var tokiMark: some View {
        TokiLogoMark(size: Self.markInk / Self.markInkRatio, showsBackground: false)
            .frame(width: Self.markInk, height: Self.markInk)
            .clipped()
    }

    /// Matches the 18pt AppKit uses for a template status icon inside the 22pt bar.
    private static let markInk: CGFloat = 18
    /// Share of the asset's square that the glyph actually inks.
    private static let markInkRatio: CGFloat = 0.57

    // Two half-height rows instead of one full-height one, so a two-provider readout costs
    // roughly half the width. The entries handed in already respect the density's cap; this
    // prefix is the backstop that keeps a third row from being drawn into a band with no
    // vertical room for it.
    private var stackedEntries: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.prefix(density.maxSegments)) { entry in
                segment(for: entry)
                    .frame(height: 11)
            }
        }
    }

    private func segment(for entry: MenuBarStatusEntry) -> some View {
        HStack(spacing: metrics.segmentSpacing) {
            if let leadingText = entry.leadingText {
                Text(leadingText)
                    .font(.system(size: metrics.glyphSize - 1, weight: .regular))
            } else {
                ProviderLogo(provider: entry.provider, size: metrics.glyphSize)
            }
            Text(displayValue(for: entry))
                .font(.system(size: metrics.valueSize, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: metrics.valueMinWidth, alignment: .trailing)
        }
    }

    // Compact only. The percent sign is the one character carrying no information the glyph
    // beside it doesn't already imply, so the density whose whole job is width spends it on
    // something else. Stacked has already halved the width by going vertical and has the room
    // to keep it. Cost readouts ("$12.30") have no percent sign and are left alone.
    private func displayValue(for entry: MenuBarStatusEntry) -> String {
        guard density == .compact, entry.value.hasSuffix("%") else { return entry.value }
        return String(entry.value.dropLast())
    }

    private var metrics: Metrics { Metrics(density: density) }

    private struct Metrics {
        var density: MenuBarDensity

        var glyphSize: CGFloat {
            switch density {
            case .comfortable: return 13
            case .compact: return 11
            case .stacked: return 9
            }
        }

        var valueSize: CGFloat {
            switch density {
            case .comfortable: return 13
            case .compact: return 11
            case .stacked: return 9
            }
        }

        var groupSpacing: CGFloat {
            switch density {
            case .comfortable: return 8
            case .compact: return 5
            case .stacked: return 5
            }
        }

        var segmentSpacing: CGFloat {
            switch density {
            case .comfortable: return 4
            case .compact: return 3
            case .stacked: return 4
            }
        }

        var valueMinWidth: CGFloat {
            switch density {
            case .comfortable: return 30
            case .compact: return 22
            // Wide enough for "100%", which is the longest thing a stacked row draws.
            case .stacked: return 24
            }
        }

        /// Breathing room against whatever sits next to Toki on the bar. Stacked gets more of
        /// it: two short rows read as a single dense block, so the same 2pt that suits a
        /// single-row readout leaves it looking wedged against its neighbours.
        var horizontalPadding: CGFloat {
            switch density {
            case .comfortable, .compact: return 2
            case .stacked: return 5
            }
        }
    }

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
