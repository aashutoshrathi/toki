import AppKit
import Foundation

enum DiagnosticLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private let queue = DispatchQueue(label: "local.toki.diagnostics")
    private let fileManager = FileManager.default
    private let maximumBytes: UInt64 = 512 * 1024
    // Mirrors log lines to the in-app debug panel while debug mode is on. Only touched on `queue`
    // so reads (from record) and writes (from setObserver) never race.
    private var observer: (@Sendable (String) -> Void)?

    // Set to a handler while debug mode is on, or nil to detach; serialized on the log queue.
    func setObserver(_ observer: (@Sendable (String) -> Void)?) {
        queue.async { [self] in self.observer = observer }
    }

    var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".toki/logs", isDirectory: true)
    }

    var currentLogURL: URL {
        logDirectoryURL.appendingPathComponent("toki.log")
    }

    func record(_ level: DiagnosticLevel, component: String, code: String, detail: String? = nil) {
        queue.async { [self] in
            if let observer {
                var summary = "\(level.rawValue) [\(component)] \(code)"
                if let detail, !detail.isEmpty { summary += " \(redacted(detail))" }
                observer(summary)
            }
            do {
                try fileManager.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
                try rotateIfNeeded()
                let timestamp = ISO8601DateFormatter().string(from: Date())
                var line = "\(timestamp) \(level.rawValue) [\(safeToken(component))] \(safeToken(code))"
                if let detail, !detail.isEmpty {
                    line += " \(redacted(detail))"
                }
                line += "\n"
                let data = Data(line.utf8)
                if !fileManager.fileExists(atPath: currentLogURL.path) {
                    try data.write(to: currentLogURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: currentLogURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }
            } catch {
                // Diagnostics must never create another application failure.
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func rotateIfNeeded() throws {
        pruneExpiredArchives()
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentLogURL.path) else { return }
        let size = attributes[.size] as? UInt64 ?? 0
        let created = attributes[.creationDate] as? Date ?? Date()
        guard size >= maximumBytes || Date().timeIntervalSince(created) >= Self.retention else { return }

        for index in stride(from: 2, through: 1, by: -1) {
            let source = logDirectoryURL.appendingPathComponent("toki.log.\(index)")
            let destination = logDirectoryURL.appendingPathComponent("toki.log.\(index + 1)")
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        let firstArchive = logDirectoryURL.appendingPathComponent("toki.log.1")
        try? fileManager.removeItem(at: firstArchive)
        try fileManager.moveItem(at: currentLogURL, to: firstArchive)
    }

    private func pruneExpiredArchives() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let reportsDirectory = logDirectoryURL.appendingPathComponent("reports", isDirectory: true)
        let reports = ((try? fileManager.contentsOfDirectory(atPath: reportsDirectory.path)) ?? [])
            .map { reportsDirectory.appendingPathComponent($0) }
        for url in archiveURLs + reports {
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static let retention: TimeInterval = 30 * 86_400

    var archiveURLs: [URL] {
        (1...3).map { logDirectoryURL.appendingPathComponent("toki.log.\($0)") }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func safeToken(_ value: String) -> String {
        value.lowercased().map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" ? character : "_"
        }.reduce(into: "", { $0.append($1) })
    }

    private func redacted(_ value: String) -> String {
        var result = value
        let home = fileManager.homeDirectoryForCurrentUser.path
        result = result.replacingOccurrences(of: home, with: "~")
        result = replacingMatches(in: result, pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, with: "<redacted-email>")
        result = replacingMatches(in: result, pattern: #"(?i)(bearer|token|secret|api[_-]?key|password)\s*[:=]?\s*[^\s,;]+"#, with: "$1=<redacted>")
        result = replacingMatches(in: result, pattern: #"(?i)\b(sk-[A-Za-z0-9]{20,}|[A-Za-z0-9+/]{40,}={0,2})\b"#, with: "<redacted-credential>")
        result = replacingMatches(in: result, pattern: #"https?://[^\s?#]+[?][^\s]+"#, with: "<redacted-url-query>")
        result = replacingMatches(in: result, pattern: #"\b[0-9a-fA-F]{24,}\b"#, with: "<redacted-id>")
        return String(result.prefix(500))
    }

    private func replacingMatches(in value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

func recordAPIFailure(_ url: URL?, method: String = "GET", error: Error) {
    DiagnosticLogger.shared.record(
        .error,
        component: "api",
        code: "request_failed",
        detail: "\(method) \(apiEndpointDescription(url)) \(diagnosticErrorDetail(error))"
    )
}

func apiEndpointDescription(_ url: URL?) -> String {
    guard let url, let host = url.host else { return "<unknown-endpoint>" }
    let segments = url.path.split(separator: "/").map { segment -> String in
        let value = String(segment)
        let isIdentifier = value.count >= 8 && value.allSatisfy { $0.isHexDigit || $0 == "-" } && value.contains(where: \.isNumber)
        return isIdentifier || value.allSatisfy(\.isNumber) ? ":id" : value
    }
    return "\(host)/\(segments.joined(separator: "/"))"
}

// Every detail here goes through `redacted()` before it is written, so carrying the message
// is safe. Dropping it is not: a decode failure logged as bare `type=DecodingError` says the
// incident happened and nothing about which field caused it.
func diagnosticErrorDetail(_ error: Error) -> String {
    if let http = error as? HTTPStatusError {
        let body = http.body.prefix(200)
        return body.isEmpty
            ? "type=HTTPStatusError status=\(http.statusCode)"
            : "type=HTTPStatusError status=\(http.statusCode) body=\(body)"
    }
    if let urlError = error as? URLError {
        return "type=URLError code=\(urlError.errorCode) detail=\(urlError.localizedDescription)"
    }
    if let decoding = error as? DecodingError {
        return "type=DecodingError \(decodingErrorDetail(decoding))"
    }
    // Domain and code pin down a system error even when its message is generic -
    // NSCocoaErrorDomain 3840 is a JSON parse failure, NSOSStatusErrorDomain a Keychain
    // refusal. Only genuine NSErrors qualify; a bridged Swift error's domain would just
    // restate the type name.
    if type(of: error) is NSError.Type {
        let nsError = error as NSError
        return "type=NSError domain=\(nsError.domain) code=\(nsError.code) detail=\(nsError.localizedDescription)"
    }
    return "type=\(String(describing: type(of: error))) detail=\(error.localizedDescription)"
}

// The coding path is the whole point: it names the field that broke.
private func decodingErrorDetail(_ error: DecodingError) -> String {
    func path(_ context: DecodingError.Context) -> String {
        let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
        return keys.isEmpty ? "<root>" : keys
    }
    switch error {
    case let .keyNotFound(key, context):
        return "kind=keyNotFound key=\(key.stringValue) at=\(path(context))"
    case let .typeMismatch(type, context):
        return "kind=typeMismatch expected=\(type) at=\(path(context))"
    case let .valueNotFound(type, context):
        return "kind=valueNotFound expected=\(type) at=\(path(context))"
    case let .dataCorrupted(context):
        return "kind=dataCorrupted at=\(path(context)) detail=\(context.debugDescription)"
    @unknown default:
        return "kind=unknown"
    }
}

enum DiagnosticsReporter {
    static let supportEmail = "toki@aashutosh.dev"
    static let newIssueURL = "https://github.com/aashutoshrathi/toki/issues/new"

    @MainActor
    static func reportBug() {
        let reportURL: URL
        do {
            reportURL = try makeReport()
        } catch {
            DiagnosticLogger.shared.record(.error, component: "diagnostics", code: "report_failed", detail: diagnosticErrorDetail(error))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Report a bug"
        alert.informativeText = """
        Toki saved a debug report with the last 30 days of logs. Email it to \(supportEmail), or attach it to a new GitHub issue, and describe what went wrong.

        The report leaves out credentials, prompts, file paths and account settings.
        """
        alert.addButton(withTitle: "Email Report")
        alert.addButton(withTitle: "Open GitHub Issue")
        alert.addButton(withTitle: "Show in Finder")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            emailReport(reportURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([reportURL])
            if let url = issueURL() { NSWorkspace.shared.open(url) }
        default:
            NSWorkspace.shared.activateFileViewerSelecting([reportURL])
        }
    }

    @MainActor
    private static func emailReport(_ reportURL: URL) {
        let subject = "Toki \(appVersion) bug report"
        let body = "What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n"
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body, reportURL]) {
            service.recipients = [supportEmail]
            service.subject = subject
            service.perform(withItems: [body, reportURL])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([reportURL])
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body + "\n(Please attach \(reportURL.lastPathComponent) from the Finder window Toki opened.)\n")
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private static func issueURL() -> URL? {
        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Bug: "),
            URLQueryItem(name: "body", value: """
            **What happened**


            **What I expected**


            **Steps to reproduce**


            Toki \(appVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

            Debug report: drag the Toki-Bug-Report file from the Finder window Toki opened into this box.
            """)
        ]
        return components?.url
    }

    static func openLogFolder() {
        try? FileManager.default.createDirectory(
            at: DiagnosticLogger.shared.logDirectoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(DiagnosticLogger.shared.logDirectoryURL)
    }

    static func makeReport() throws -> URL {
        DiagnosticLogger.shared.flush()
        let reportsDirectory = DiagnosticLogger.shared.logDirectoryURL.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let reportURL = reportsDirectory.appendingPathComponent("Toki-Bug-Report-\(stamp).txt")
        var report = """
        Toki debug report
        App version: \(appVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architectureName())
        Generated: \(ISO8601DateFormatter().string(from: Date()))

        This report intentionally excludes account configuration, credentials, prompts, file paths, workspace names, and session titles.

        Logs:
        """
        let logFiles = DiagnosticLogger.shared.archiveURLs.reversed() + [DiagnosticLogger.shared.currentLogURL]
        let logs = logFiles.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined()
        report += logs.isEmpty ? "\nNo diagnostic entries.\n" : "\n\(logs)"
        try SecureStore.write(data: Data(report.utf8), to: reportURL)
        return reportURL
    }

    private static func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
