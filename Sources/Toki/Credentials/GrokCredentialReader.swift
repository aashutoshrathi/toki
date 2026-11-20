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
        if requiresUniqueAccount, json.keys.filter({ $0.contains("::") }).count > 1 {
            return Credentials(email: nil)
        }
        let idToken = firstString(in: json, keys: ["id_token", "idToken"])
        let claims = idToken.flatMap(jwtPayload)
        let email = claims.flatMap { firstString(in: $0, keys: ["email", "Email"]) }
            ?? firstString(in: json, keys: ["email", "Email"])
        return Credentials(email: email)
    }
}
