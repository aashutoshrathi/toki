import Foundation

func shellEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

func expandedPath(_ rawPath: String) -> String {
    if rawPath == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
    if rawPath.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(rawPath.dropFirst(2)))
            .path
    }
    return rawPath
}
