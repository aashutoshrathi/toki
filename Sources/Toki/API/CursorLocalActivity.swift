import Foundation

enum CursorLocalActivity {
    static func latest(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Date? {
        var newest: Date?
        let tracking = "\(home)/.cursor/ai-tracking/ai-code-tracking.db"
        if FileManager.default.fileExists(atPath: tracking),
           let raw = Shell.output("/usr/bin/sqlite3", ["-readonly", tracking, "SELECT MAX(createdAt) FROM ai_code_hashes;"]),
           let ms = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), ms > 0 {
            newest = Date(timeIntervalSince1970: ms / 1000)
        }

        let chatsRoot = "\(home)/.cursor/chats"
        if let workspaces = try? FileManager.default.contentsOfDirectory(atPath: chatsRoot) {
            for workspace in workspaces {
                let workspaceDir = "\(chatsRoot)/\(workspace)"
                guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: workspaceDir) else { continue }
                for session in sessions {
                    let meta = "\(workspaceDir)/\(session)/meta.json"
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: meta)),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ms = json["updatedAtMs"] as? Double, ms > 0 else { continue }
                    let updated = Date(timeIntervalSince1970: ms / 1000)
                    if newest == nil || updated > newest! { newest = updated }
                }
            }
        }
        return newest
    }
}
