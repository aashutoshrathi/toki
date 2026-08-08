import Foundation

struct LocalizedErrorMessage: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ClaudeSignInExpiredError: LocalizedError {
    var accountLabel: String?
    var isActiveAccount: Bool

    var errorDescription: String? {
        if isActiveAccount {
            return "Sign-in expired. Open Claude Code to renew it - Toki picks the new token up on its own."
        }
        let account = accountLabel.map { " for \($0)" } ?? ""
        return "Stored sign-in expired\(account). Run claude-swap to switch to it once, which renews the token."
    }
}

struct HTTPStatusError: LocalizedError {
    var statusCode: Int
    var body: String

    var errorDescription: String? {
        "HTTP \(statusCode): \(body.prefix(140))"
    }
}
