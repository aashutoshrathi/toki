import Foundation

// T3 Code starts `claude` itself, and its own database is the only record of which chat a
// Claude session belongs to and what that chat is called.
enum T3CodeThreadStore {
    struct Thread: Hashable, Sendable {
        let id: String
        let title: String?
        let url: URL?
        let mobileOSes: [String]
    }

    private static var installedUserData: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.t3/userdata"
    }

    static func threads(forSessionPaths sessionPaths: [String]) -> [String: Thread] {
        threads(forSessionPaths: sessionPaths, userData: installedUserData)
    }

    /// Keyed by the transcript path each thread was looked up with.
    static func threads(forSessionPaths sessionPaths: [String], userData: String) -> [String: Thread] {
        // Interpolated into the query, so nothing but a UUID gets that far.
        let pathsBySessionID = Dictionary(
            sessionPaths.compactMap { path -> (String, String)? in
                let id = sessionID(of: path)
                return UUID(uuidString: id) == nil ? nil : (id, path)
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !pathsBySessionID.isEmpty,
              let raw = Shell.output(
                  "/usr/bin/sqlite3",
                  ["-readonly", "-separator", "\u{1f}", "\(userData)/statev2.sqlite", threadQuery(sessionIDs: Array(pathsBySessionID.keys))]
              ) else {
            return [:]
        }
        var found: [String: (id: String, title: String?)] = [:]
        for row in raw.split(separator: "\n") {
            let fields = row.components(separatedBy: "\u{1f}")
            guard fields.count == 3, let path = pathsBySessionID[fields[0]], !fields[1].isEmpty else { continue }
            let title = fields[2].trimmingCharacters(in: .whitespaces)
            found[path] = (fields[1], title.isEmpty ? nil : title)
        }
        guard !found.isEmpty else { return [:] }
        let environmentID = readEnvironmentID(userData: userData)
        let mobileOSes = readMobileOSes(userData: userData)
        return found.mapValues { thread in
            Thread(
                id: thread.id,
                title: thread.title,
                url: environmentID.flatMap { URL(string: "t3code://threads/\($0)/\(thread.id)") },
                mobileOSes: mobileOSes
            )
        }
    }

    struct OpenThread: Sendable, Equatable {
        let thread: Thread
        let driver: String
        let directory: String?
        let nativeID: String?
        let updated: Date?
    }

    static func openThreads(limit: Int = 40) -> [OpenThread] {
        openThreads(userData: installedUserData, limit: limit)
    }

    /// T3 Code stops a chat's provider process once the chat goes idle, so the chats it still has
    /// open are read from its database, newest first.
    static func openThreads(userData: String, limit: Int = 40) -> [OpenThread] {
        guard let raw = Shell.output(
            "/usr/bin/sqlite3",
            ["-readonly", "-separator", "\u{1f}", "\(userData)/statev2.sqlite", openThreadsQuery(limit: limit)]
        ) else {
            return []
        }
        let rows = raw.split(separator: "\n").map { $0.components(separatedBy: "\u{1f}") }.filter { $0.count == 6 }
        guard !rows.isEmpty else {
            return []
        }
        let environmentID = readEnvironmentID(userData: userData)
        let mobileOSes = readMobileOSes(userData: userData)
        return rows.map { fields in
            let title = fields[5].trimmingCharacters(in: .whitespaces)
            return OpenThread(
                thread: Thread(
                    id: fields[0],
                    title: title.isEmpty ? nil : title,
                    url: environmentID.flatMap { URL(string: "t3code://threads/\($0)/\(fields[0])") },
                    mobileOSes: mobileOSes
                ),
                driver: fields[1],
                directory: fields[3].isEmpty ? nil : fields[3],
                nativeID: fields[4].isEmpty ? nil : fields[4],
                updated: parseTimestamp(fields[2])
            )
        }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func readEnvironmentID(userData: String) -> String? {
        guard let id = (try? String(contentsOfFile: "\(userData)/environment-id", encoding: .utf8))?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }
        return id
    }

    private static func readMobileOSes(userData: String) -> [String] {
        guard let raw = Shell.output("/usr/bin/sqlite3", ["-readonly", "\(userData)/statev2.sqlite", mobileOSQuery]) else {
            return []
        }
        return raw.split(separator: "\n").map(String.init)
    }

    private static func sessionID(of sessionPath: String) -> String {
        ((sessionPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // Oldest first, so a session T3 has bound to more than one thread resolves to the newest.
    private static func threadQuery(sessionIDs: [String]) -> String {
        let list = sessionIDs.map { "'\($0)'" }.joined(separator: ",")
        return """
        SELECT json_extract(p.payload_json, '$.nativeThreadRef.nativeId'),
               p.thread_id,
               replace(replace(ifnull(t.title, ''), char(10), ' '), char(13), ' ')
        FROM orchestration_v2_projection_provider_threads p
        LEFT JOIN orchestration_v2_projection_threads t ON t.thread_id = p.thread_id
        WHERE json_extract(p.payload_json, '$.nativeThreadRef.nativeId') IN (\(list))
        ORDER BY p.updated_at;
        """
    }

    private static func openThreadsQuery(limit: Int) -> String {
        """
        SELECT t.thread_id,
               ifnull(s.driver, s.provider),
               t.updated_at,
               ifnull(json_extract(s.payload_json, '$.cwd'), ''),
               ifnull((SELECT json_extract(p.payload_json, '$.nativeThreadRef.nativeId')
                       FROM orchestration_v2_projection_provider_threads p
                       WHERE p.thread_id = t.thread_id
                       ORDER BY p.updated_at DESC LIMIT 1), ''),
               replace(replace(t.title, char(10), ' '), char(13), ' ')
        FROM orchestration_v2_projection_threads t
        JOIN orchestration_v2_projection_provider_sessions s ON s.thread_id = t.thread_id
        WHERE s.status = 'ready' AND t.archived_at IS NULL AND t.deleted_at IS NULL
        GROUP BY t.thread_id
        ORDER BY t.updated_at DESC
        LIMIT \(max(1, limit));
        """
    }

    private static let mobileOSQuery = """
    SELECT DISTINCT client_os
    FROM auth_sessions
    WHERE client_surface = 'mobile'
      AND client_os IS NOT NULL
      AND revoked_at IS NULL
      AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
    """
}
