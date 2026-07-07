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
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder.toki.decode(UsageState.self, from: data) else {
            return UsageState()
        }
        return state
    }

    static func save(_ state: UsageState) {
        let path = Self.path
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.toki.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
