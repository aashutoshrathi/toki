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

    var body: some View {
        SVGLogoMark(asset: "toki-logo", size: size) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Image(systemName: "wallet.pass")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityLabel("/toki")
    }
}
