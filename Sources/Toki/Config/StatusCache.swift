import Foundation

// Per-account detail for `Toki status --json` / the human-readable list. Mirrors the
// live AccountSnapshot fields a CLI consumer would actually want; not the full snapshot.
struct StatusCacheEntry: Codable, Sendable {
    var id: String
    var name: String
    var provider: Provider
    var primary: String
    var remainingRatio: Double?
    var isError: Bool
}

// Snapshot of "what the popover would show right now," written by the running app after
// every real refresh and read by the `Toki status` CLI. The CLI never fetches live - it
// only reads this file - so it stays instant even though live snapshots require network
// calls and Keychain access that have no place running on every shell prompt render.
struct StatusCache: Codable, Sendable {
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
    //
    // updatedAt is the caller's last-real-refresh timestamp, not Date() at write time:
    // this is also called after preference-only changes (see UsageStore.updatePreferences),
    // which recompute derived state from the same snapshots without actually refreshing
    // them. Stamping "now" there would make the cache look fresh and defeat the CLI's
    // stale-cache warning.
    //
    // The actual encode+write happens off the @MainActor caller: this is invoked from
    // updateDerivedState(), which updatePreferences() calls on every change - and Settings
    // sliders emit a change per drag tick, not just on release. Keeping directory-check +
    // JSON encode + atomic write on a background task avoids stuttering the UI on a drag.
    static func write(snapshots: [AccountSnapshot], recommendation: SmartRecommendation, menuBarEntries: [MenuBarStatusEntry], updatedAt: Date) {
        guard !snapshots.isEmpty, !snapshots.allSatisfy(\.isLoadingPlaceholder) else { return }

        let cache = StatusCache(
            updatedAt: updatedAt,
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
        let writePath = path

        Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: writePath)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SecureStore.write(data: JSONEncoder.toki.encode(cache), to: url)
            } catch {
                DiagnosticLogger.shared.record(.error, component: "status_cache", code: "save_failed", detail: diagnosticErrorDetail(error))
            }
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
