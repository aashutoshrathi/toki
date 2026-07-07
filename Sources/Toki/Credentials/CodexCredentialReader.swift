import Foundation

enum CodexCredentialReader {
    static func readCredentials(account: AccountConfig) throws -> CodexCredentials {
        if let token = try explicitAccessToken(account: account) {
            return CodexCredentials(
                accessToken: token,
                accountID: nil,
                authMode: nil,
                email: nil,
                source: "Configured token"
            )
        }

        let path = expandedPath(account.codexAuthPath ?? "~/.codex/auth.json")
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalizedErrorMessage("Missing Codex auth at \(path)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw LocalizedErrorMessage("No Codex OAuth access token found")
        }

        let idToken = tokens["id_token"] as? String
        let claims = idToken.flatMap(jwtPayload)
        return CodexCredentials(
            accessToken: accessToken,
            accountID: tokens["account_id"] as? String,
            authMode: json["auth_mode"] as? String,
            email: claims.flatMap { firstString(in: $0, keys: ["email", "preferred_username", "username"]) },
            source: path
        )
    }

    static func accountInfo(from credentials: CodexCredentials) -> [MetricLine] {
        var lines: [MetricLine] = []
        if let authMode = credentials.authMode {
            lines.append(MetricLine(label: "Auth", value: authMode))
        }
        if let email = credentials.email {
            lines.append(MetricLine(label: "Email", value: email))
        }
        if let accountID = credentials.accountID {
            lines.append(MetricLine(label: "Account", value: compactIdentifier(accountID)))
        }
        lines.append(MetricLine(label: "Source", value: credentials.source))
        return lines
    }

    private static func explicitAccessToken(account: AccountConfig) throws -> String? {
        if let apiKey = account.apiKey, !apiKey.isEmpty {
            return apiKey
        }
        if let envName = account.apiKeyEnv,
           let value = ProcessInfo.processInfo.environment[envName],
           !value.isEmpty {
            return value
        }
        if let command = account.apiKeyCommand, !command.isEmpty {
            let value = try SecretResolver.runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
