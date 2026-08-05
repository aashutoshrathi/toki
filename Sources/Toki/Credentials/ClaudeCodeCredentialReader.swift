import Foundation

enum ClaudeCodeCredentialReader {
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

    // Claude Code keeps its sign-in in the Keychain on macOS, but not always: a Keychain-less
    // setup writes ~/.claude/.credentials.json instead. Reading only one of the two reported a
    // signed-in install as not connected, so both are tried and a failure names both.
    static func readSignedInCredentials() throws -> CredentialBundle {
        var attempts: [String] = []
        do {
            return try readMacOSKeychainCredentials()
        } catch {
            attempts.append("Keychain item \"Claude Code-credentials\" (\(shortReason(error)))")
        }
        do {
            return try readCredentialsFile()
        } catch {
            attempts.append("\(credentialsFilePath) (\(shortReason(error)))")
        }
        throw LocalizedErrorMessage(
            "Couldn't find your Claude Code sign-in. Open Claude Code and run /login, then hit refresh in Toki. Toki looked in \(attempts.joined(separator: " and "))."
        )
    }

    static func readCredentialsFile() throws -> CredentialBundle {
        let path = expandedPath(credentialsFilePath)
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalizedErrorMessage("no such file")
        }
        guard let credentials = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw LocalizedErrorMessage("the file couldn't be read (check its permissions)")
        }
        let trimmed = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalizedErrorMessage("the file is empty")
        }
        return CredentialBundle(credentials: trimmed, source: credentialsFilePath)
    }

    static func extractAccessToken(from credentials: String) throws -> String {
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
        return token
    }

    private static func keyList(_ json: [String: Any]) -> String {
        let keys = json.keys.sorted()
        return keys.isEmpty ? "nothing" : keys.joined(separator: ", ")
    }

    // The per-source messages are written to stand alone, so quoting them whole inside the
    // combined "looked in A and B" sentence repeats its own advice back twice.
    private static func shortReason(_ error: Error) -> String {
        let detail = error.localizedDescription
        if detail.lowercased().contains("could not be found") || detail.contains("No Claude Code credentials found") {
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
        let credentials = try readKeychain(service: "Claude Code-credentials", account: user)
        return CredentialBundle(credentials: credentials, source: "Keychain \(user)")
        #else
        throw LocalizedErrorMessage("Claude Code Keychain lookup is macOS-only")
        #endif
    }

    static func readKeychain(service: String, account: String) throws -> String {
        #if os(macOS)
        let command = "security find-generic-password -s '\(shellEscaped(service))' -a '\(shellEscaped(account))' -w"
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
