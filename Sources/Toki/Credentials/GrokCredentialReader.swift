import Foundation

// Reads ~/.grok/auth.json - the Grok CLI's (xAI's own "Grok Build" coding agent) cached
// sign-in. Read-only and local-only: Toki never talks to xAI's auth endpoints itself, it
// only checks whether the CLI already has a live-looking credential cached, the same way
// ProviderDetection checks Claude Code, Codex, and Gemini for onboarding.
//
// There is deliberately no usage/quota lookup here - the CLI's own subcommand surface
// (`grok --help`) has no account/usage/billing command, so like Gemini and Copilot, Grok
// is detection-only. The email is best-effort: pulled from an id_token JWT if one is
// cached, falling back to a plain top-level field if the CLI ever stores it that way.
enum GrokCredentialReader {
    struct Credentials {
        var email: String?
    }

    static func readCredentials(path: String = "~/.grok/auth.json") throws -> Credentials {
        let expanded = expandedPath(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LocalizedErrorMessage("No Grok CLI credentials found")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalizedErrorMessage("No Grok CLI credentials found")
        }
        let idToken = firstString(in: json, keys: ["id_token", "idToken"])
        let claims = idToken.flatMap(jwtPayload)
        let email = claims.flatMap { firstString(in: $0, keys: ["email", "Email"]) }
            ?? firstString(in: json, keys: ["email", "Email"])
        return Credentials(email: email)
    }
}
