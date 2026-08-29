import Foundation

let appVersion = "3.0.0"
let appUserAgent = "Toki/\(appVersion)"

/// Display label for the prerelease part of a release identity, or nil for a stable build.
///
/// `appVersion` is only the marketing version, because CFBundleShortVersionString has to stay
/// dotted-numeric. The suffix that says *which* beta you are on lives in the full identity the
/// release scripts stamp into Info.plist, so it has to be read back out to be shown.
func prereleaseBadge(for releaseVersion: String) -> String? {
    guard let separator = releaseVersion.firstIndex(of: "-") else { return nil }
    let suffix = releaseVersion[releaseVersion.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
    guard !suffix.isEmpty else { return nil }
    // "beta.3" reads as "BETA 3"; a bare "rc" keeps its own shape.
    return suffix.split(separator: ".").joined(separator: " ").uppercased()
}
// GitHub Pages renders docs/*.md from the default branch; the extensionless path is the HTML one.
let docsBaseURL = "https://toki.aashutosh.dev/docs"
let remoteControlGuideURL = URL(string: "\(docsBaseURL)/remote-control")!
let defaultConfigPath = "~/.toki/config.json"
let defaultStatePath = "~/.toki/usage-state.json"
let legacyConfigPath = "~/.tokenbar/config.json"
let legacyStatePath = "~/.tokenbar/usage-state.json"
nonisolated(unsafe) var debugLogHandler: ((String) -> Void)?
