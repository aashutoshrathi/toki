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
            return "Access token expired. Open Claude Code or try /status in an existing session, then refresh Toki. Use /login only if Claude Code cannot restore access."
        }
        let account = accountLabel.map { " for \($0)" } ?? ""
        return "Stored access token expired\(account). Switch to it with claude-swap, open Claude Code, and try /status, then refresh Toki. Use /login only if Claude Code cannot restore access."
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
