import Foundation

struct LocalizedErrorMessage: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ClaudeSignInExpiredError: LocalizedError, Equatable {
    var accountLabel: String?
    var isActiveAccount: Bool

    var errorDescription: String? {
        if isActiveAccount {
            return "Sign-in expired. Open Claude Code to renew it - Toki picks the new token up on its own."
        }
        let account = accountLabel.map { " for \($0)" } ?? ""
        return "Stored sign-in expired\(account). Switch to it with claude-swap, then renew the sign-in in Claude Code."
    }
}

struct HTTPStatusError: LocalizedError {
    var statusCode: Int
    var body: String

    var errorDescription: String? {
        "HTTP \(statusCode): \(body.prefix(140))"
    }
}

struct ResetNotAttempted: LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}

struct RedeemedReset: Equatable, Sendable {
    let outcome: String
    let creditExpiry: Date?
}
