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
            return UsageState()
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
