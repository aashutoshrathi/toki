import Foundation

enum StateLoader {
    static var path: String {
        if let path = ProcessInfo.processInfo.environment["TOKI_STATE"], !path.isEmpty {
            return expandedPath(path)
        }
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_STATE"], !path.isEmpty {
            return expandedPath(path)
        }

        let preferred = expandedPath(defaultStatePath)
        let legacy = expandedPath(legacyStatePath)
        if !FileManager.default.fileExists(atPath: preferred),
           FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return preferred
    }

    static func load() -> UsageState {
        let path = Self.path
        guard FileManager.default.fileExists(atPath: path) else {
            return UsageState()
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder.toki.decode(UsageState.self, from: data)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "state", code: "load_failed", detail: diagnosticErrorDetail(error))
            // Falling back to an empty state means the next save overwrites whatever could not
            // be read - silently destroying accumulated history over what may be a single
            // unrecognized field. Set the unreadable file aside first so it is recoverable.
            preserveUnreadableState(at: path)
            return UsageState()
        }
    }

    private static func preserveUnreadableState(at path: String) {
        let backup = path + ".unreadable"
        try? FileManager.default.removeItem(atPath: backup)
        do {
            try FileManager.default.copyItem(atPath: path, toPath: backup)
            DiagnosticLogger.shared.record(.warning, component: "state", code: "state_preserved", detail: backup)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "state", code: "state_preserve_failed", detail: diagnosticErrorDetail(error))
        }
    }

    static func save(_ state: UsageState) {
        let path = Self.path
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SecureStore.write(data: JSONEncoder.toki.encode(state), to: url)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "state", code: "save_failed", detail: diagnosticErrorDetail(error))
        }
    }
}
