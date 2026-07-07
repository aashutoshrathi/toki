import AppKit
import Foundation

enum ConfigLoader {
    static var path: String {
        if let path = ProcessInfo.processInfo.environment["TOKI_CONFIG"], !path.isEmpty {
            return expandedPath(path)
        }
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_CONFIG"], !path.isEmpty {
            return expandedPath(path)
        }

        let preferred = expandedPath(defaultConfigPath)
        let legacy = expandedPath(legacyConfigPath)
        if !FileManager.default.fileExists(atPath: preferred),
           FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return preferred
    }

    static func load() throws -> AppConfig {
        let path = Self.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalizedErrorMessage("Missing config at \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        guard !config.accounts.isEmpty else {
            throw LocalizedErrorMessage("Config has no accounts")
        }
        return config
    }

    static func save(_ config: AppConfig) throws {
        let url = URL(fileURLWithPath: path)
        let data = try JSONEncoder.toki.encode(config)
        try data.write(to: url, options: .atomic)
    }

    static func openInDefaultEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
