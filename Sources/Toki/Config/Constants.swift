import Foundation

let appVersion = "2.3.3"
let appUserAgent = "Toki/\(appVersion)"
let defaultConfigPath = "~/.toki/config.json"
let defaultStatePath = "~/.toki/usage-state.json"
let defaultStatusCachePath = "~/.toki/status.json"
let legacyConfigPath = "~/.tokenbar/config.json"
let legacyStatePath = "~/.tokenbar/usage-state.json"
nonisolated(unsafe) var debugLogHandler: ((String) -> Void)?
