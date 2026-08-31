import AppKit
import SwiftUI

// MARK: - ProviderLogo

struct ProviderLogo: View {
    var provider: Provider
    var size: CGFloat

    var body: some View {
        Group {
            switch provider {
            case .claude, .claudeCode, .anthropic:
                SVGLogoMark(asset: "claude-logo", size: size) {
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                }
            case .codex:
                SVGLogoMark(asset: "codex-logo", size: size) {
                    OpenAILogoMark()
                        .foregroundStyle(Color(red: 0.48, green: 0.61, blue: 1))
                }
            case .openCode:
                SVGLogoMark(asset: "opencode-logo", size: size) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(Color(red: 0.20, green: 0.72, blue: 0.48))
                }
            case .openai, .chatgpt:
                OpenAILogoMark()
                    .foregroundStyle(Color.primary)
            case .copilot:
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.72, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.95))
            case .cursor:
                SVGLogoMark(asset: "cursor-logo", size: size) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            case .antigravity:
                SVGLogoMark(asset: "antigravity-logo", size: size) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            case .fx:
                SVGLogoMark(asset: "fx-logo", size: size, template: true) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: size * 0.68, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .foregroundStyle(Color.primary)
            case .sarvamCode:
                SVGLogoMark(asset: "sarvam-code-logo", size: size, template: true) {
                    Text("S")
                        .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                }
                .foregroundStyle(Color.primary)
            case .grok:
                SVGLogoMark(asset: "grok-logo", size: size, template: true) {
                    Image(systemName: "asterisk")
                        .font(.system(size: size * 0.72, weight: .bold))
                        .foregroundStyle(Color.primary)
                }
                .foregroundStyle(Color.primary)
            case .gemini:
                SVGLogoMark(asset: "gemini-logo", size: size) {
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.66, green: 0.33, blue: 0.97)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            case .pi:
                // Official Pi press-kit badge: https://pi.dev/press-kit
                SVGLogoMark(asset: "pi-logo", size: size) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            case .manual:
                Circle()
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

// MARK: - SVG asset loading

// Loads named SVGs from the app's Resources folder, cached per name. Drop a
// `<name>.svg` into Sources/Toki/Resources to add or replace a provider logo.
enum SVGLogoAsset {
    // Only successful loads are cached. A handful of these logos are resolved as early as
    // the menu bar status item's first render, before the rest of the app has finished
    // setting up - if that first probe ever came back nil for a transient reason, caching
    // the miss would lock the fallback SF Symbol in for the rest of the process's life,
    // since nothing else ever calls back in to retry it. Re-probing a genuine miss on
    // every render is cheap (a few file existence checks), so there's no real cost here.
    @MainActor private static var cache: [String: NSImage] = [:]

    // template: true renders the SVG as a monochrome mask that follows .foregroundStyle,
    // for single-color marks (like Grok's) that need to adapt to light/dark instead of
    // shipping with a baked-in fill color the way the other brand-color logos do.
    @MainActor static func image(named name: String, template: Bool = false) -> NSImage? {
        if let cached = cache[name] { return cached }
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        // Resources ship as raw files in Contents/Resources (see package-release.sh), so we
        // resolve via Bundle.main rather than Bundle.module - the SPM accessor fatal-errors
        // when its .bundle isn't at the app root, which conflicts with codesign's layout.
        let urls = [
            Bundle.main.url(forResource: name, withExtension: "svg"),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).svg"),
            executableDir?.deletingLastPathComponent().appendingPathComponent("Resources/\(name).svg"),
            // `swift run Toki` (the documented dev workflow, see README) never produces a
            // real .app - resources land in an SPM-generated bundle right next to the
            // executable instead of Contents/Resources, which none of the candidates above
            // reach.
            executableDir?.appendingPathComponent("Toki_Toki.bundle/\(name).svg")
        ]
        guard let image = urls.compactMap({ $0 }).lazy.compactMap({ NSImage(contentsOf: $0) }).first else {
            return nil
        }
        image.isTemplate = template
        cache[name] = image
        return image
    }
}

struct SVGLogoMark<Fallback: View>: View {
    var asset: String
    var size: CGFloat
    var template: Bool = false
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        Group {
            if let image = SVGLogoAsset.image(named: asset, template: template) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback()
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - OpenAI Logo

struct OpenAILogoMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .stroke(lineWidth: 1.7)
                    .frame(width: 9.5, height: 5.5)
                    .offset(x: 3.6)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
    }
}

// MARK: - Toki Logo

struct TokiLogoMark: View {
    var size: CGFloat
    /// The glass tile the mark sits on. Wanted wherever the logo reads as an app icon, but
    /// not in the menu bar, where a tile behind a status item reads as a floating card.
    var showsBackground = true

    var body: some View {
        if showsBackground {
            mark.functionalGlass(
                in: RoundedRectangle(cornerRadius: size * 0.286, style: .continuous)
            )
            .accessibilityLabel("/toki")
        } else {
            mark.accessibilityLabel("/toki")
        }
    }

    // The router glyph and its two status dots. The SVG carries the glyph alone, so anything
    // drawing it bare gets a mark that is missing half the logo.
    private var mark: some View {
        ZStack {
            SVGLogoMark(asset: "toki-router-mark", size: size, template: true) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: size * 0.52, weight: .semibold))
            }
            .foregroundStyle(.primary)

            Circle()
                .fill(Color(red: 0.56, green: 0.66, blue: 0.61))
                .frame(width: size * 0.076, height: size * 0.076)
                .offset(x: size * 0.229, y: size * -0.219)

            Circle()
                .fill(Color(red: 0.79, green: 0.60, blue: 0.32))
                .frame(width: size * 0.076, height: size * 0.076)
                .offset(x: size * 0.227, y: size * 0.197)
        }
        .frame(width: size, height: size)
    }
}
