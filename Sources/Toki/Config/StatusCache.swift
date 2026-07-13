import Foundation

// Per-account detail for `toki status --json` / the human-readable list. Mirrors the
// live AccountSnapshot fields a CLI consumer would actually want; not the full snapshot.
struct StatusCacheEntry: Codable {
    var id: String
    var name: String
    var provider: Provider
    var primary: String
    var remainingRatio: Double?
    var isError: Bool
}

// Snapshot of "what the popover would show right now," written by the running app after
// every real refresh and read by the `toki status` CLI. The CLI never fetches live - it
// only reads this file - so it stays instant even though live snapshots require network
// calls and Keychain access that have no place running on every shell prompt render.
struct StatusCache: Codable {
    var updatedAt: Date
    var recommendationTitle: String
    var recommendationDetail: String
    var menuBarEntries: [MenuBarStatusEntry]
    var accounts: [StatusCacheEntry]
}

enum StatusCacheStore {
    static var path: String {
        if let path = ProcessInfo.processInfo.environment["TOKI_STATUS_CACHE"], !path.isEmpty {
            return expandedPath(path)
        }
        return expandedPath(defaultStatusCachePath)
    }

    // Skips loading placeholders (empty ratio, "Refreshing" primary) so a config
    // reload or app relaunch never clobbers the last real snapshot with blanks while
    // the first fetch is still in flight.
    static func write(snapshots: [AccountSnapshot], recommendation: SmartRecommendation, menuBarEntries: [MenuBarStatusEntry]) {
        guard !snapshots.isEmpty, !snapshots.allSatisfy(\.isLoadingPlaceholder) else { return }

        let cache = StatusCache(
            updatedAt: Date(),
            recommendationTitle: recommendation.title,
            recommendationDetail: recommendation.detail,
            menuBarEntries: menuBarEntries,
            accounts: snapshots.map {
                StatusCacheEntry(
                    id: $0.id,
                    name: $0.name,
                    provider: $0.provider,
                    primary: $0.primary,
                    remainingRatio: $0.remainingRatio,
                    isError: $0.isError
                )
            }
        )

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.toki.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            DiagnosticLogger.shared.record(.error, component: "status_cache", code: "save_failed", detail: diagnosticErrorDetail(error))
        }
    }

    static func load() -> StatusCache? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder.toki.decode(StatusCache.self, from: data)
    }
}
