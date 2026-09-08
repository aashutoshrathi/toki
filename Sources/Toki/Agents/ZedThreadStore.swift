import Foundation

// Zed keeps one row per agent thread in its own SQLite database - the same list its threads
// sidebar renders - and that row is the only place a Zed session names itself. The ACP servers
// Zed launches are never told which thread they are serving, and Zed's built-in agent runs
// inside the app with no process of its own, so a `ps` scan alone can name neither.
enum ZedThreadStore {
    struct Thread: Sendable, Equatable {
        // Zed's label for the agent behind the thread ("Claude Code", "Gemini CLI"). Empty for
        // Zed's own agent: it is stored as a null and read back as the built-in.
        let agentName: String
        let title: String?
        let updated: Date?
        let directory: String?

        var isNative: Bool { agentName.isEmpty }

        var displayAgentName: String { isNative ? "Zed Agent" : agentName }
    }

    // Zed writes one database per release channel, and several channels can be installed side by
    // side, so every `0-<channel>` folder is read rather than assuming stable.
    static func databasePaths() -> [String] {
        let root = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Application Support/Zed/db"
        guard let channels = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return channels.sorted()
            .map { "\(root)/\($0)/db.sqlite" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func isInstalled() -> Bool {
        if !databasePaths().isEmpty { return true }
        return ["/Applications/Zed.app", "~/Applications/Zed.app", "/Applications/Zed Preview.app"]
            .map { ($0 as NSString).expandingTildeInPath }
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Threads across every installed channel, most recently updated first.
    static func threads(limit: Int = 40) -> [Thread] {
        databasePaths()
            .flatMap { threads(inDatabase: $0, limit: limit) }
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// The thread a running agent belongs to, matched on the project folder Zed recorded for it.
    /// Zed hands an ACP server the worktree as its working directory, so the folder is the only
    /// link between the two, and the most recently updated thread in it is the live one.
    static func thread(forDirectory directory: String, in threads: [Thread]) -> Thread? {
        let target = (directory as NSString).resolvingSymlinksInPath
        return threads.first { thread in
            guard let recorded = thread.directory else { return false }
            return (recorded as NSString).resolvingSymlinksInPath == target
        }
    }

    // The sidebar list, newest first. `main_worktree_paths` and `folder_paths` are newline-joined
    // path lists and rows come back newline-separated, so the first path is cut out in SQL rather
    // than splitting a row that would already have been mangled.
    private static func listQuery(limit: Int) -> String {
        """
        SELECT agent_id, title, updated_at,
               CASE WHEN instr(paths, char(10)) > 0 THEN substr(paths, 1, instr(paths, char(10)) - 1) ELSE paths END
        FROM (SELECT ifnull(agent_id, '') AS agent_id,
                     replace(replace(ifnull(nullif(title_override, ''), ifnull(title, '')), char(10), ' '), char(13), ' ') AS title,
                     ifnull(updated_at, '') AS updated_at,
                     ifnull(nullif(main_worktree_paths, ''), ifnull(folder_paths, '')) AS paths
              FROM sidebar_threads
              WHERE ifnull(archived, 0) = 0
              ORDER BY updated_at DESC
              LIMIT \(max(1, limit)));
        """
    }

    // Zed added title_override and main_worktree_paths in later migrations, so an install that
    // has not run them yet answers the query above with an error rather than rows.
    private static func legacyListQuery(limit: Int) -> String {
        """
        SELECT agent_id, title, updated_at,
               CASE WHEN instr(paths, char(10)) > 0 THEN substr(paths, 1, instr(paths, char(10)) - 1) ELSE paths END
        FROM (SELECT ifnull(agent_id, '') AS agent_id,
                     replace(replace(ifnull(title, ''), char(10), ' '), char(13), ' ') AS title,
                     ifnull(updated_at, '') AS updated_at,
                     ifnull(folder_paths, '') AS paths
              FROM sidebar_threads
              ORDER BY updated_at DESC
              LIMIT \(max(1, limit)));
        """
    }

    private struct CacheEntry {
        let signature: String
        let threads: [Thread]
        let succeeded: Bool
        let readAt: Date
    }
    private nonisolated(unsafe) static var cache: [String: CacheEntry] = [:]

    /// A read that failed says nothing about what the database holds, so it is only held long
    /// enough to keep a channel with no threads table from being re-queried on every scan.
    private static let failedReadRetryInterval: TimeInterval = 60

    /// Zed runs SQLite in WAL mode, so a committed thread lands in `-wal` and leaves the main
    /// file's modification date untouched until a checkpoint. Keyed on that date alone, the
    /// first read of the process was served for the life of the app: a thread started after
    /// Toki launched never appeared, and one that was live at launch went stale and vanished.
    private static func signature(of path: String) -> String {
        [path, path + "-wal"].map { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let size = (attributes?[.size] as? Int) ?? -1
            return "\(modified):\(size)"
        }.joined(separator: "|")
    }

    static func threads(inDatabase path: String, limit: Int) -> [Thread] {
        let now = Date()
        let signature = signature(of: path)
        if let cached = cache[path], cached.signature == signature,
           cached.succeeded || now.timeIntervalSince(cached.readAt) < failedReadRetryInterval {
            return cached.threads
        }
        let raw = read(database: path, query: listQuery(limit: limit))
            ?? read(database: path, query: legacyListQuery(limit: limit))
        let threads = (raw?.split(separator: "\n").compactMap(parse(row:)) ?? [])
        cache[path] = CacheEntry(signature: signature, threads: threads, succeeded: raw != nil, readAt: now)
        return threads
    }

    private static func read(database: String, query: String) -> String? {
        Shell.output("/usr/bin/sqlite3", ["-readonly", "-separator", "\u{1f}", database, query])
    }

    static func parse(row: Substring) -> Thread? {
        let fields = row.components(separatedBy: "\u{1f}")
        guard fields.count == 4 else { return nil }
        let title = fields[1].trimmingCharacters(in: .whitespaces)
        let directory = fields[3].trimmingCharacters(in: .whitespaces)
        return Thread(
            agentName: fields[0].trimmingCharacters(in: .whitespaces),
            title: title.isEmpty ? nil : title,
            updated: date(fromRFC3339: fields[2]),
            directory: directory.hasPrefix("/") ? directory : nil
        )
    }

    // Zed writes RFC 3339 with fractional seconds sometimes and without others, and the default
    // formatter rejects whichever it was not configured for.
    static func date(fromRFC3339 value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
