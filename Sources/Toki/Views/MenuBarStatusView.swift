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
                    .font(.system(size: metrics.textSize, weight: .bold))
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

    // The asset is an app-icon canvas, so most of it is transparent padding meant for a
    // squircle. Drawn at icon size the mark reads as a speck, so it is drawn oversized and
    // cropped back, throwing away the margin rather than the detail.
    private var tokiMark: some View {
        TokiLogoMark(size: Self.markInk / Self.markInkRatio, showsBackground: false)
            .frame(width: Self.markInk, height: Self.markInk)
            .clipped()
    }

    private static let markInk: CGFloat = 18
    private static let markInkRatio: CGFloat = 0.57

    // The entries handed in already respect the cap; this prefix keeps a third row from being
    // drawn into a band with no vertical room for it.
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
                    .font(.system(size: metrics.textSize - 1, weight: .regular))
            } else {
                ProviderLogo(provider: entry.provider, size: metrics.textSize)
            }
            Text(menuBarDisplayValue(entry.value, density: density))
                .font(.system(size: metrics.textSize, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: metrics.valueMinWidth, alignment: .trailing)
        }
    }

    private var metrics: Metrics { Metrics(density: density) }

    private struct Metrics {
        var density: MenuBarDensity

        var textSize: CGFloat {
            switch density {
            case .comfortable: return 13
            case .compact: return 11
            case .stacked: return 9
            }
        }

        var groupSpacing: CGFloat {
            switch density {
            case .comfortable: return 8
            case .compact, .stacked: return 5
            }
        }

        var segmentSpacing: CGFloat {
            switch density {
            case .comfortable, .stacked: return 4
            case .compact: return 3
            }
        }

        var valueMinWidth: CGFloat {
            switch density {
            case .comfortable: return 30
            case .compact: return 22
            case .stacked: return 24
            }
        }

        // Two short rows read as one dense block, so the 2pt that suits a single row leaves
        // Stacked wedged against its neighbours on the bar.
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
