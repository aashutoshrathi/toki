import Foundation

// Reads ~/.gemini/oauth_creds.json - the Gemini CLI's Google OAuth token cache, written
// on `gemini` sign-in. Read-only and local-only: Toki never talks to Google's OAuth
// endpoints itself, it only checks whether the CLI already has a live-looking token
// cached, the same way ProviderDetection checks Claude Code and Codex for onboarding.
//
// There is deliberately no usage/quota lookup here - unlike Claude Code and Codex,
// Google's own gemini-cli client has no "remaining quota" API call anywhere in it either
// (checked its shipped source directly), so Gemini is detection-only, like Copilot.
enum GeminiCredentialReader {
    struct Credentials {
        var email: String?
    }

    static func readCredentials(path: String = "~/.gemini/oauth_creds.json") throws -> Credentials {
        let expanded = expandedPath(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LocalizedErrorMessage("No Gemini CLI credentials found")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw LocalizedErrorMessage("No Gemini CLI OAuth access token found")
        }
        let idToken = json["id_token"] as? String
        let claims = idToken.flatMap(jwtPayload)
        return Credentials(email: claims.flatMap { firstString(in: $0, keys: ["email"]) })
    }
}
