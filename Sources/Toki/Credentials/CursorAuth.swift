import Foundation

enum CursorAuth {
    struct Credentials {
        let token: String
        let userId: String
    }

    enum Login {
        case missing
        case connected(Credentials)
    }

    static func read(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Login {
        if let credentials = desktopCredentials(home: home) ?? cliCredentials(home: home) {
            return .connected(credentials)
        }
        return .missing
    }

    private static func desktopCredentials(home: String) -> Credentials? {
        let db = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: db),
              let stored = Shell.output("/usr/bin/sqlite3", ["-readonly", db,
                "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        // Encrypted desktop sign-ins require Cursor's Keychain item, which can open
        // a macOS permission dialog during refresh. Only use plaintext tokens here.
        guard let credentials = credentials(token: stored) else { return nil }
        // An expired desktop token must not hide a current CLI session.
        if let expiry = jwtPayload(stored)?["exp"] as? TimeInterval, expiry.isFinite,
           expiry <= Date().timeIntervalSince1970 { return nil }
        return credentials
    }

    private struct CLISession: Decodable {
        let accessToken: String
    }

    private static func cliCredentials(home: String) -> Credentials? {
        let path = "\(home)/.cursor/auth.json"
        var info = stat()
        // A local file supplies an account credential. Only trust a bounded regular
        // file owned by the current user and protected against other users' writes.
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size > 0, info.st_size <= 256 * 1024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let session = try? JSONDecoder().decode(CLISession.self, from: data),
              let expiry = jwtPayload(session.accessToken)?["exp"] as? TimeInterval,
              expiry.isFinite, expiry > Date().timeIntervalSince1970 else { return nil }
        return credentials(token: session.accessToken)
    }

    private static func credentials(token: String) -> Credentials? {
        guard token.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,
                          options: .regularExpression) != nil,
              let userId = jwtSubject(token),
              userId.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return Credentials(token: token, userId: userId)
    }

    static func jwtSubject(_ token: String) -> String? {
        guard let sub = jwtPayload(token)?["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }
}
