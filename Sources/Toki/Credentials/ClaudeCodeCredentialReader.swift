import Foundation

enum ClaudeCodeCredentialReader {
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
        return try readMacOSKeychainCredentials()
    }

    static func extractAccessToken(from credentials: String) throws -> String {
        // try? rather than try: a parse failure must not escape as the raw Cocoa error
        // ("The data couldn't be read..."), which names neither the data nor a remedy.
        guard let data = credentials.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LocalizedErrorMessage("Claude Code credentials are not valid JSON - the credential source returned something other than the expected JSON payload")
        }
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw LocalizedErrorMessage("No Claude Code OAuth access token found")
        }
        return token
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
