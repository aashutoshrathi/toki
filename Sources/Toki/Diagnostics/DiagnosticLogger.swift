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

    var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".toki/logs", isDirectory: true)
    }

    var currentLogURL: URL {
        logDirectoryURL.appendingPathComponent("toki.log")
    }

    func record(_ level: DiagnosticLevel, component: String, code: String, detail: String? = nil) {
        queue.async { [self] in
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
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentLogURL.path),
              let size = attributes[.size] as? UInt64,
              size >= maximumBytes else { return }

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
    @MainActor private static var activePicker: NSSharingServicePicker?

    @MainActor
    static func presentSharePicker() {
        do {
            let reportURL = try makeReport()
            guard let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView else {
                throw LocalizedErrorMessage("No window is available for the share picker.")
            }
            let picker = NSSharingServicePicker(items: [reportURL])
            activePicker = picker
            picker.show(
                relativeTo: view.bounds,
                of: view,
                preferredEdge: .maxY
            )
        } catch {
            DiagnosticLogger.shared.record(.error, component: "diagnostics", code: "report_failed", detail: diagnosticErrorDetail(error))
        }
    }

    static func openLogFolder() {
        try? FileManager.default.createDirectory(
            at: DiagnosticLogger.shared.logDirectoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(DiagnosticLogger.shared.logDirectoryURL)
    }

    private static func makeReport() throws -> URL {
        DiagnosticLogger.shared.flush()
        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Toki-Debug-Report-\(UUID().uuidString).txt")
        var report = """
        Toki debug report
        App version: \(appVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architectureName())
        Generated: \(ISO8601DateFormatter().string(from: Date()))

        This report intentionally excludes account configuration, credentials, prompts, file paths, workspace names, and session titles.

        Logs:
        """
        if let data = try? Data(contentsOf: DiagnosticLogger.shared.currentLogURL),
           let logs = String(data: data, encoding: .utf8) {
            report += "\n\(logs)"
        } else {
            report += "\nNo diagnostic entries.\n"
        }
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
