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

    private static let mobileOSQuery = """
    SELECT DISTINCT client_os
    FROM auth_sessions
    WHERE client_surface = 'mobile'
      AND client_os IS NOT NULL
      AND revoked_at IS NULL
      AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
    """
}
