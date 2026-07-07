import Foundation

struct LocalizedErrorMessage: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct HTTPStatusError: LocalizedError {
    var statusCode: Int
    var body: String

    var errorDescription: String? {
        "HTTP \(statusCode): \(body.prefix(140))"
    }
}
