import Foundation

enum ClaudeCodeCredentialReader {
    static let keychainService = "Claude Code-credentials"
    static let credentialsFilePath = "~/.claude/.credentials.json"

    struct CredentialBundle {
        var credentials: String
        var source: String
    }

    static func readCredentials(account: AccountConfig) throws -> CredentialBundle {
        if let apiKey = account.apiKey, !apiKey.isEmpty {
            return CredentialBundle(credentials: apiKey, source: "Config")
        }
        if let envName = account.apiKeyEnv,
           let value = ProcessInfo.processInfo.environment[envName],
           !value.isEmpty {
            return CredentialBundle(credentials: value, source: "Env \(envName)")
        }
        if let command = account.apiKeyCommand, !command.isEmpty {
            let credentials = try SecretResolver.runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
            return CredentialBundle(credentials: credentials, source: "Command")
        }
        return try readSignedInCredentials()
    }

    // Claude Code keeps its sign-in in the Keychain on macOS, but not always, and not always
    // where you'd expect: a Keychain-less setup writes .credentials.json instead, CLAUDE_CONFIG_DIR
    // moves the whole config directory, and an XDG-style install puts it under ~/.config. Reading
    // one fixed location reported a genuinely signed-in machine as not connected, so the search
    // walks every known spot and a failure names each one it tried.
    static func readSignedInCredentials() throws -> CredentialBundle {
        var attempts: [String] = []
        for account in keychainAccountCandidates() {
            do {
                return try keychainBundle(account: account)
            } catch {
                attempts.append("Keychain \(account.map { "item for \"\($0)\"" } ?? "item, any account") (\(shortReason(error)))")
                // Only a missing item is worth retrying under another name. A denied or timed-out
                // access prompt would put the same dialog up again for each remaining candidate,
                // each one waiting out the same long timeout.
                guard isMissingKeychainItem(error) else { break }
            }
        }
        for path in credentialFileCandidates() {
            do {
                return try readCredentialsFile(at: path)
            } catch {
                attempts.append("\(path) (\(shortReason(error)))")
            }
        }
        throw LocalizedErrorMessage(
            "Couldn't find your Claude Code sign-in. Open Claude Code and run /login, then hit refresh in Toki. Toki looked in \(attempts.joined(separator: ", "))."
        )
    }

    // The Keychain item is stored under the account that created it, which is not always the name
    // Toki computes: a renamed short name, a managed account, or a login under a different user
    // all break the exact-account lookup. The final nil falls back to a service-only search, which
    // finds the item whatever account it is filed under.
    static func keychainAccountCandidates() -> [String?] {
        var names: [String?] = []
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty {
            names.append(user)
        }
        let nsUser = NSUserName()
        if !nsUser.isEmpty, !names.contains(where: { $0 == nsUser }) {
            names.append(nsUser)
        }
        names.append(nil)
        return names
    }

    // Login-shell values are consulted only after the plain locations miss, so the usual case
    // never pays for a subprocess. A Finder-launched app inherits none of the user's shell
    // environment, so CLAUDE_CONFIG_DIR set in a profile is invisible without asking for it.
    static func credentialFileCandidates(includeShellEnvironment: Bool = true) -> [String] {
        var paths: [String] = []
        func add(_ path: String?) {
            guard let path, isUsableConfigDirectory(path) else { return }
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            let candidate = "\(normalized)/.credentials.json"
            if !paths.contains(candidate) { paths.append(candidate) }
        }

        let environment = ProcessInfo.processInfo.environment
        add(environment["CLAUDE_CONFIG_DIR"])
        add("~/.claude")
        add(environment["XDG_CONFIG_HOME"].map { "\($0)/claude" })
        add("~/.config/claude")

        if includeShellEnvironment {
            let shellEnvironment = loginShellConfigDirectories()
            add(shellEnvironment.claudeConfigDir)
            add(shellEnvironment.xdgConfigHome.map { "\($0)/claude" })
        }
        return paths
    }

    // These two come from the environment, and one of them is read back out of a login shell, so
    // they get checked before being turned into a path Toki will open. A relative value would
    // resolve against whatever directory the app happens to be launched from, and control
    // characters have no business in a config path.
    static func isUsableConfigDirectory(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") || path.hasPrefix("~/") || path == "~" else { return false }
        return !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static let shellEnvironmentLock = NSLock()
    private nonisolated(unsafe) static var cachedShellEnvironment: (claudeConfigDir: String?, xdgConfigHome: String?)?

    // One subprocess, both variables, and a short timeout: this runs on the failure path where
    // the alternative is telling a signed-in user they are not connected. Cached because a
    // not-connected account is re-read on every refresh, and a shell profile does not move.
    static func loginShellConfigDirectories() -> (claudeConfigDir: String?, xdgConfigHome: String?) {
        shellEnvironmentLock.lock()
        defer { shellEnvironmentLock.unlock() }
        if let cachedShellEnvironment { return cachedShellEnvironment }

        let separator = "__TOKI_ENV__"
        let command = "printf '%s\(separator)%s' \"$CLAUDE_CONFIG_DIR\" \"$XDG_CONFIG_HOME\""
        let result: (claudeConfigDir: String?, xdgConfigHome: String?)
        if let output = try? SecretResolver.runShell(command, timeout: 5) {
            let parts = output.components(separatedBy: separator)
            let claudeDir = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let xdgDir = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            result = (claudeDir?.isEmpty == false ? claudeDir : nil, xdgDir?.isEmpty == false ? xdgDir : nil)
        } else {
            result = (nil, nil)
        }
        cachedShellEnvironment = result
        return result
    }

    // A real .credentials.json is a few hundred bytes. The cap stops a file that only shares the
    // name from being slurped into memory before anything has looked at whether it makes sense.
    static let maximumCredentialFileBytes: off_t = 256 * 1024

    // What comes out of this file is sent to api.anthropic.com as a Bearer token, so the search
    // widening that made it reachable also has to make it trustworthy. A file someone else owns
    // or can write is not this user's sign-in, whatever it is called, and following a symlink
    // would let the name stand in for a file chosen somewhere else entirely.
    static func readCredentialsFile(at rawPath: String = credentialsFilePath) throws -> CredentialBundle {
        let path = expandedPath(rawPath)
        var info = stat()
        // lstat, not stat: the symlink itself is the thing being judged, not its target.
        guard lstat(path, &info) == 0 else {
            throw LocalizedErrorMessage("no such file")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw LocalizedErrorMessage("not a regular file")
        }
        guard info.st_uid == getuid() else {
            throw LocalizedErrorMessage("owned by another user, so it isn't your sign-in")
        }
        guard info.st_mode & (mode_t(S_IWGRP) | mode_t(S_IWOTH)) == 0 else {
            throw LocalizedErrorMessage("writable by other users, so its contents can't be trusted (chmod 600 it)")
        }
        guard info.st_size > 0 else {
            throw LocalizedErrorMessage("the file is empty")
        }
        guard info.st_size <= maximumCredentialFileBytes else {
            throw LocalizedErrorMessage("far bigger than a credentials file should be, so it wasn't read")
        }
        guard let credentials = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw LocalizedErrorMessage("the file couldn't be read (check its permissions)")
        }
        let trimmed = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalizedErrorMessage("the file is empty")
        }
        if info.st_mode & (mode_t(S_IRGRP) | mode_t(S_IROTH)) != 0 {
            DiagnosticLogger.shared.record(.warning, component: "claude_credentials", code: "world_readable",
                                           detail: "\(rawPath) is readable by other users")
        }
        return CredentialBundle(credentials: trimmed, source: rawPath)
    }

    struct OAuthToken {
        var accessToken: String
        var expiresAt: Date?

        static let expiryLeeway: TimeInterval = 60

        func isExpired(asOf now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= OAuthToken.expiryLeeway
        }
    }

    static func extractAccessToken(from credentials: String) throws -> String {
        try extractToken(from: credentials).accessToken
    }

    static func extractToken(from credentials: String) throws -> OAuthToken {
        // try? rather than try: a parse failure must not escape as the raw Cocoa error
        // ("The data couldn't be read..."), which names neither the data nor a remedy.
        guard let data = credentials.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LocalizedErrorMessage("Claude Code credentials are not valid JSON - the credential source returned something other than the expected JSON payload")
        }
        // Naming the keys that were there, and only the keys, turns "no token found" into
        // something a user can act on without ever putting a secret on screen.
        guard let oauth = json["claudeAiOauth"] as? [String: Any] else {
            throw LocalizedErrorMessage(
                "Your Claude Code credentials have no \"claudeAiOauth\" section, which is the subscription sign-in Toki reads usage from. Open Claude Code, run /login, and choose your Claude account (an API key or Bedrock/Vertex setup doesn't report usage). Found instead: \(keyList(json))."
            )
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw LocalizedErrorMessage(
                "Your Claude Code sign-in has no access token in it. Open Claude Code and run /login again, then hit refresh in Toki. The sign-in holds: \(keyList(oauth))."
            )
        }
        return OAuthToken(accessToken: token, expiresAt: expiryDate(from: oauth["expiresAt"]))
    }

    static func expiryDate(from value: Any?) -> Date? {
        let milliseconds: Double
        switch value {
        case let number as NSNumber:
            milliseconds = number.doubleValue
        case let text as String:
            guard let parsed = Double(text) else { return nil }
            milliseconds = parsed
        default:
            return nil
        }
        guard milliseconds > 0, milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func keyList(_ json: [String: Any]) -> String {
        let keys = json.keys.sorted()
        return keys.isEmpty ? "nothing" : keys.joined(separator: ", ")
    }

    static func isMissingKeychainItem(_ error: Error) -> Bool {
        let detail = error.localizedDescription
        return detail.lowercased().contains("could not be found")
            || detail.contains("No Claude Code credentials found")
    }

    // The per-source messages are written to stand alone, so quoting them whole inside the
    // combined "looked in A and B" sentence repeats its own advice back twice.
    private static func shortReason(_ error: Error) -> String {
        let detail = error.localizedDescription
        if isMissingKeychainItem(error) {
            return "not there"
        }
        if let first = detail.split(separator: ".").first {
            return String(first).trimmingCharacters(in: .whitespaces)
        }
        return detail
    }

    static func emailIdentifier(from credentials: String) -> String? {
        guard let json = credentialJSON(credentials) else { return nil }
        return Toki.emailIdentifier(in: json)
    }

    static func organizationName(from credentials: String) -> String? {
        guard let json = credentialJSON(credentials) else { return nil }
        return firstString(in: json, keys: ["organizationName", "organization_name", "orgName", "workspaceName"])
    }

    static func organizationUUID(from credentials: String) -> String? {
        guard let json = credentialJSON(credentials) else { return nil }
        return firstString(in: json, keys: ["organizationUuid", "organizationId", "organization_id"])
    }

    static func accountInfo(from credentials: String, source: String) -> [MetricLine] {
        var lines = [MetricLine(label: "Source", value: source)]

        guard let data = credentials.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return lines
        }

        if let email = Toki.emailIdentifier(in: json) {
            lines.append(MetricLine(label: "Email", value: email))
        } else if let account = firstString(in: json, keys: ["accountEmail", "account_email", "login", "username", "preferred_username"]) {
            lines.append(MetricLine(label: "Account", value: account))
        }
        if let org = firstString(in: json, keys: ["organizationName", "organization_name", "orgName", "workspaceName"]) {
            lines.append(MetricLine(label: "Org", value: org))
        }
        if let id = firstString(in: json, keys: ["organizationUuid", "organizationId", "organization_id", "accountUuid", "accountId"]) {
            lines.append(MetricLine(label: "ID", value: compactIdentifier(id)))
        }
        if let scope = firstString(in: json, keys: ["scope", "scopes"]) {
            lines.append(MetricLine(label: "Scope", value: scope))
        }

        return lines
    }

    static func readMacOSKeychainCredentials() throws -> CredentialBundle {
        #if os(macOS)
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return try keychainBundle(account: user)
        #else
        throw LocalizedErrorMessage("Claude Code Keychain lookup is macOS-only")
        #endif
    }

    static func keychainBundle(account: String?) throws -> CredentialBundle {
        #if os(macOS)
        let credentials = try readKeychain(service: keychainService, account: account)
        return CredentialBundle(credentials: credentials, source: "Keychain \(account ?? "(any account)")")
        #else
        throw LocalizedErrorMessage("Claude Code Keychain lookup is macOS-only")
        #endif
    }

    // A nil account searches the service alone. `security` matches the first item with that
    // service whatever account it carries, which is the only way to reach an item filed under a
    // name Toki cannot derive.
    static func readKeychain(service: String, account: String?) throws -> String {
        #if os(macOS)
        let accountFlag = account.map { " -a '\(shellEscaped($0))'" } ?? ""
        let command = "security find-generic-password -s '\(shellEscaped(service))'\(accountFlag) -w"
        // Deliberately a long timeout, not the default.
        //
        // The first read on a machine puts up the system's Keychain access prompt, and
        // `security` blocks until it is answered. Under the default 15 seconds that clock is
        // really measuring how quickly the user notices a dialog - miss it and the read is
        // killed, the account reports as not connected, and nothing indicates that a prompt was
        // the reason. A generous ceiling still guards against a genuinely wedged process.
        let credentials: String
        do {
            credentials = try SecretResolver.runShell(command, timeout: 120)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // "Allow the prompt" is only the right advice when a prompt actually appeared. Telling
            // someone with no Keychain item to click Allow sends them looking for a dialog that
            // will never show up, so the item-not-found case gets its own answer.
            let detail = error.localizedDescription
            if detail.lowercased().contains("could not be found") {
                throw LocalizedErrorMessage(
                    "No Claude Code credentials found in your Keychain. Sign in to Claude Code, then refresh."
                )
            }
            throw LocalizedErrorMessage(
                "Couldn't read the Claude Code credentials from your Keychain: \(detail). If macOS asked for Keychain access, choose Allow and refresh."
            )
        }
        guard !credentials.isEmpty else {
            throw LocalizedErrorMessage("Keychain item is empty")
        }
        return credentials
        #else
        throw LocalizedErrorMessage("Keychain lookup is macOS-only")
        #endif
    }

    private static func credentialJSON(_ credentials: String) -> [String: Any]? {
        guard let data = credentials.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
