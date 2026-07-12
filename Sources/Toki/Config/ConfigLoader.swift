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
        try validate(config)
        migrateToFlatShapeIfNeeded(rawData: data, config: config, path: path)
        return config
    }

    // The invariants a config must satisfy, shared by load() and the in-app editor.
    static func validate(_ config: AppConfig) throws {
        guard !config.accounts.isEmpty else {
            throw LocalizedErrorMessage("Config has no accounts")
        }
        guard !config.accounts.contains(where: { $0.provider == .copilot }) else {
            throw LocalizedErrorMessage("Copilot is detected automatically in the Agents tab and is not a usage-ledger account")
        }
    }

    // One-time rewrite of legacy configs (name/provider keys) into the flat label/type
    // shape. A .bak copy is kept before overwriting so the original is recoverable.
    private static func migrateToFlatShapeIfNeeded(rawData: Data, config: AppConfig, path: String) {
        guard let text = String(data: rawData, encoding: .utf8),
              text.contains("\"provider\"") || text.contains("\"name\"") else {
            return
        }
        do {
            try rawData.write(to: URL(fileURLWithPath: path + ".bak"), options: .atomic)
            let migrated = try JSONEncoder.toki.encode(config)
            try migrated.write(to: URL(fileURLWithPath: path), options: .atomic)
            DiagnosticLogger.shared.record(.info, component: "config", code: "migrated_flat_shape")
        } catch {
            DiagnosticLogger.shared.record(.warning, component: "config", code: "migration_failed", detail: diagnosticErrorDetail(error))
        }
    }

    static func save(_ config: AppConfig) throws {
        let url = URL(fileURLWithPath: path)
        let data = try JSONEncoder.toki.encode(config)
        try data.write(to: url, options: .atomic)
    }

    static func openInDefaultEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func rawContents() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // Validates raw JSON with the same rules as load() before writing, so a bad edit is
    // rejected in the UI rather than persisted and breaking the next launch.
    static func saveRaw(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw LocalizedErrorMessage("Config is not valid UTF-8")
        }
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        try validate(config)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
