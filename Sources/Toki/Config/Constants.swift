import Foundation

let appVersion = "2.6.0"
let appUserAgent = "Toki/\(appVersion)"
// GitHub Pages renders docs/*.md from the default branch; the extensionless path is the HTML one.
let docsBaseURL = "https://toki.aashutosh.dev/docs"
let remoteControlGuideURL = URL(string: "\(docsBaseURL)/remote-control")!
let defaultConfigPath = "~/.toki/config.json"
let defaultStatePath = "~/.toki/usage-state.json"
let legacyConfigPath = "~/.tokenbar/config.json"
let legacyStatePath = "~/.tokenbar/usage-state.json"
nonisolated(unsafe) var debugLogHandler: ((String) -> Void)?
