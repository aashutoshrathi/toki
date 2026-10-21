import Foundation

// T3 Code starts `claude` itself, and its own database is the only record of which chat a
// Claude session belongs to.
enum T3CodeThreadStore {
    static func threadURL(forSessionPath sessionPath: String) -> URL? {
        threadURL(
            forSessionPath: sessionPath,
            userData: "\(FileManager.default.homeDirectoryForCurrentUser.path)/.t3/userdata"
        )
    }

    static func threadURL(forSessionPath sessionPath: String, userData: String) -> URL? {
        let sessionID = ((sessionPath as NSString).lastPathComponent as NSString).deletingPathExtension
        // Interpolated into the query, so nothing but a UUID gets that far.
        guard UUID(uuidString: sessionID) != nil,
              let environmentID = try? String(contentsOfFile: "\(userData)/environment-id", encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentID.isEmpty,
              let threadID = Shell.output("/usr/bin/sqlite3", ["-readonly", "\(userData)/statev2.sqlite", threadQuery(sessionID: sessionID)])?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty else {
            return nil
        }
        return URL(string: "t3code://threads/\(environmentID)/\(threadID)")
    }

    private static func threadQuery(sessionID: String) -> String {
        """
        SELECT thread_id FROM orchestration_v2_projection_provider_threads
        WHERE json_extract(payload_json, '$.nativeThreadRef.nativeId') = '\(sessionID)'
        ORDER BY updated_at DESC
        LIMIT 1;
        """
    }
}
