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

    // Best-effort parse used by UsageStore.connect() to distinguish a file that exists and
    // decodes fine but merely fails validate() (e.g. no accounts yet - the exact onboarding
    // scenario) from one that doesn't decode at all. Safe to build on top of the former;
    // the latter must not be touched, or a genuinely corrupt config.json would be lost.
    static func loadRawIfParsable() -> AppConfig? {
        let path = Self.path
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
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
    // shape. A .bak copy of the true original is kept once and never overwritten.
    private static func migrateToFlatShapeIfNeeded(rawData: Data, config: AppConfig, path: String) {
        guard hasLegacyAccountKeys(rawData) else { return }
        let backupPath = path + ".bak"
        do {
            // Preserve only the FIRST original; a later spurious trigger must not clobber it.
            if !FileManager.default.fileExists(atPath: backupPath) {
                try rawData.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
            }
            let migrated = try JSONEncoder.toki.encode(config)
            try migrated.write(to: URL(fileURLWithPath: path), options: .atomic)
            DiagnosticLogger.shared.record(.info, component: "config", code: "migrated_flat_shape")
        } catch {
            DiagnosticLogger.shared.record(.warning, component: "config", code: "migration_failed", detail: diagnosticErrorDetail(error))
        }
    }

    // True only if an actual account object carries a legacy key ("name"/"provider").
    // Parsing the structure avoids false positives from those tokens appearing inside a
    // string value elsewhere (e.g. a notes field), which would re-migrate every launch.
    private static func hasLegacyAccountKeys(_ rawData: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]] else {
            return false
        }
        return accounts.contains { $0["name"] != nil || $0["provider"] != nil }
    }

    static func save(_ config: AppConfig) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
