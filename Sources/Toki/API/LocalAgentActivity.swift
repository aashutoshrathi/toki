import Foundation

enum LocalAgentActivity {
    static func claudeCode(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Date? {
        let fileManager = FileManager.default
        let projectsRoot = "\(home)/.claude/projects"
        guard let projects = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else { return nil }
        var newest: Date?
        for project in projects {
            let projectDir = "\(projectsRoot)/\(project)"
            guard let files = try? fileManager.contentsOfDirectory(atPath: projectDir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                guard let modified = modificationDate(of: "\(projectDir)/\(file)") else { continue }
                if newest.map({ modified > $0 }) ?? true { newest = modified }
            }
        }
        return newest
    }

    static func codex(codexHome: String) -> Date? {
        [codexThreadsActivity(codexHome: codexHome), newestCodexRollout(codexHome: codexHome)]
            .compactMap { $0 }
            .max()
    }

    private static func codexThreadsActivity(codexHome: String) -> Date? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: codexHome) else { return nil }
        let databases = files.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        return databases.compactMap { database -> Date? in
            let path = "\(codexHome)/\(database)"
            guard let raw = Shell.output("/usr/bin/sqlite3", ["-readonly", path, "SELECT MAX(updated_at) FROM threads;"]),
                  let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }.max()
    }

    private static func newestCodexRollout(codexHome: String) -> Date? {
        var directory = "\(codexHome)/sessions"
        for _ in 0..<3 {
            guard let newest = numericEntries(in: directory).last else { return nil }
            directory = "\(directory)/\(newest)"
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return files
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { modificationDate(of: "\(directory)/\($0)") }
            .max()
    }

    private static func numericEntries(in directory: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return entries.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted()
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
