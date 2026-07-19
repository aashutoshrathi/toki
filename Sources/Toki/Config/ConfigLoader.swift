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
            throw LocalizedErrorMessage("Config file not found")
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
        // Copilot, Grok, and Gemini are legitimate accounts with no usage API - UsageFetcher
        // renders them as agent-detection-only cards (see agentOnlySnapshot). They used to be
        // rejected here from back when nothing ever wrote them into config.json, but Grok/
        // Gemini's onboarding now does exactly that, so blocking them here would make
        // connecting - and every subsequent config reload - fail outright.
        // id is what SwiftUI's ForEach identifies account rows by, and what several
        // Dictionary lookups key snapshots on (those now use uniquingKeysWith rather than
        // uniqueKeysWithValues, so a duplicate can't crash them - but it's still confusing
        // UI/state, and cheap to reject outright here instead.
        let ids = config.accounts.map(\.id)
        guard Set(ids).count == ids.count else {
            throw LocalizedErrorMessage("Config has accounts with duplicate ids - each account needs a unique id")
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
                try SecureStore.write(data: rawData, to: URL(fileURLWithPath: backupPath))
            }
            try SecureStore.write(data: JSONEncoder.toki.encode(config), to: URL(fileURLWithPath: path))
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
        try SecureStore.write(data: JSONEncoder.toki.encode(config), to: url)
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
        try SecureStore.write(data: data, to: fileURL)
    }
}
