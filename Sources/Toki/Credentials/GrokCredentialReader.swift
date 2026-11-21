import Foundation

// Reads ~/.grok/auth.json - the Grok CLI's (xAI's own "Grok Build" coding agent) cached
// sign-in. Read-only and local-only: Toki never talks to xAI's auth endpoints itself, it
// only checks whether the CLI already has a live-looking credential cached, the same way
// ProviderDetection checks Claude Code, Codex, and Gemini for onboarding.
//
// The email is best-effort: pulled from an ID-token JWT or a cached email field.
enum GrokCredentialReader {
    struct Credentials {
        var email: String?
    }

    static func readCredentials(path: String = "~/.grok/auth.json",
                                requiresUniqueAccount: Bool = false) throws -> Credentials {
        let expanded = expandedPath(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LocalizedErrorMessage("No Grok CLI credentials found")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalizedErrorMessage("No Grok CLI credentials found")
        }
        let credential: [String: Any]
        if requiresUniqueAccount {
            // Grok ignores WebLogin credentials, including entries at the inherited scope.
            let candidates = json.compactMap { scope, value -> [String: Any]? in
                guard scope.contains("::") || scope == "https://accounts.x.ai/sign-in",
                      let entry = value as? [String: Any],
                      let mode = entry["auth_mode"] as? String, mode == "oidc" || mode == "external",
                      let key = entry["key"] as? String, !key.isEmpty else { return nil }
                return entry
            }
            guard json["xai::api_key"] == nil, candidates.count == 1, let current = candidates.first else {
                return Credentials(email: nil)
            }
            credential = current
        } else {
            credential = json
        }
        let idToken = firstString(in: credential, keys: ["id_token", "idToken"])
        let claims = idToken.flatMap(jwtPayload)
        let email = claims.flatMap { firstString(in: $0, keys: ["email", "Email"]) }
            ?? firstString(in: credential, keys: ["email", "Email"])
        if requiresUniqueAccount, email?.contains("@") != true { return Credentials(email: nil) }
        return Credentials(email: email)
    }
}
