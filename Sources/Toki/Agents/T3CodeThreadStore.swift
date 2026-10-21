import Foundation

// T3 Code starts `claude` itself, and its own database is the only record of which chat a
// Claude session belongs to and what that chat is called.
enum T3CodeThreadStore {
    struct Thread: Equatable, Sendable {
        let id: String
        let title: String?
    }

    private static var installedUserData: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.t3/userdata"
    }

    static func threads(forSessionPaths sessionPaths: [String]) -> [String: Thread] {
        threads(forSessionPaths: sessionPaths, userData: installedUserData)
    }

    static func threadURL(forSessionPath sessionPath: String) -> URL? {
        threadURL(forSessionPath: sessionPath, userData: installedUserData)
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
        var threads: [String: Thread] = [:]
        for row in raw.split(separator: "\n") {
            let fields = row.components(separatedBy: "\u{1f}")
            guard fields.count == 3, let path = pathsBySessionID[fields[0]], !fields[1].isEmpty else { continue }
            let title = fields[2].trimmingCharacters(in: .whitespaces)
            threads[path] = Thread(id: fields[1], title: title.isEmpty ? nil : title)
        }
        return threads
    }

    static func threadURL(forSessionPath sessionPath: String, userData: String) -> URL? {
        guard let thread = threads(forSessionPaths: [sessionPath], userData: userData)[sessionPath],
              let environmentID = try? String(contentsOfFile: "\(userData)/environment-id", encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentID.isEmpty else {
            return nil
        }
        return URL(string: "t3code://threads/\(environmentID)/\(thread.id)")
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
}
