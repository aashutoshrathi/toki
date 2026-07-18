import Foundation

// Pi is BYO-provider and records token/cost metadata in local JSONL session files.
// These narrow Decodable types intentionally omit message content, tool payloads, and
// every other field Toki has no reason to retain.
struct PiUsageClient {
    struct Totals: Equatable {
        var todayInput = 0.0
        var todayOutput = 0.0
        var todayCacheRead = 0.0
        var todayCacheWrite = 0.0
        var todayCost = 0.0
        var allTimeCost = 0.0
        var sessionCount = 0
    }

    struct SessionMetadata: Equatable {
        let path: String
        let title: String?
        let modified: Date?
    }

    private struct Entry: Decodable {
        let type: String
        let id: String?
        let timestamp: Timestamp?
        let cwd: String?
        let name: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let role: String
        let provider: String?
        let api: String?
        let model: String?
        let timestamp: Double?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input: Double?
        let output: Double?
        let cacheRead: Double?
        let cacheWrite: Double?
        let totalTokens: Double?
        let cost: Cost?
    }

    private struct Cost: Decodable { let total: Double? }
    private struct Settings: Decodable { let sessionDir: String? }

    private enum Timestamp: Decodable {
        case milliseconds(Double)
        case iso8601(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { self = .milliseconds(number) }
            else { self = .iso8601(try container.decode(String.self)) }
        }

        var key: String {
            switch self {
            case .milliseconds(let value): return canonical(value)
            case .iso8601(let value): return value
            }
        }
    }

    private struct IndexedFile {
        let path: String
        let modified: Date?
    }

    private final class SessionIndexCache: @unchecked Sendable {
        struct Value {
            var generation: UInt64
            var builtAt: Date
            var newestByCWD: [String: IndexedFile]
            var metadataByCWD: [String: SessionMetadata]
        }

        let lock = NSLock()
        var byRoot: [String: Value] = [:]
        var nextGeneration: UInt64 = 0
    }

    private static let indexCache = SessionIndexCache()
    private static let indexLifetime: TimeInterval = 5
    private static let maximumRecordBytes = 1024 * 1024

    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let totals = try Self.aggregate()
        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .pi,
            primary: totals.todayCost > 0 ? "\(formatUSD(totals.todayCost)) today" : "No usage today",
            subtitle: "Pi - local usage (estimated)",
            remainingRatio: nil,
            metrics: [
                MetricLine(label: "Today", value: "\(formatCompact(totals.todayInput)) in / \(formatCompact(totals.todayOutput)) out"),
                MetricLine(label: "Cache", value: "\(formatCompact(totals.todayCacheRead)) read / \(formatCompact(totals.todayCacheWrite)) write"),
                MetricLine(label: "Estimated total", value: formatUSD(totals.allTimeCost)),
                MetricLine(label: "Sessions", value: "\(totals.sessionCount)")
            ],
            isError: false
        )
    }

    static let autoDetectedID = "pi-auto"

    static func autoDetectedAccount(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> AccountConfig? {
        guard let root = try? sessionRoot(environment: environment, home: home),
              let files = try? sessionFiles(root: root),
              files.contains(where: { (try? sessionHeader(path: $0)) != nil }) else { return nil }
        return AccountConfig(id: autoDetectedID, name: "Pi", provider: .pi)
    }

    static func aggregate(root: String? = nil,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                          now: Date = Date(),
                          calendar: Calendar = .current) throws -> Totals {
        let resolvedRoot = try root ?? sessionRoot(environment: environment, home: home)
        guard FileManager.default.fileExists(atPath: resolvedRoot) else {
            throw LocalizedErrorMessage("Pi session history not found")
        }

        let candidates = try sessionFiles(root: resolvedRoot)
        var totals = Totals()
        var seen: Set<String> = []
        let startOfDay = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return totals }

        for path in candidates {
            guard try sessionHeader(path: path) != nil else { continue }
            totals.sessionCount += 1
            try forEachEntry(path: path) { entry in
                guard entry.type == "message", let message = entry.message,
                      message.role == "assistant", let usage = message.usage else { return true }

                let input = number(usage.input)
                let output = number(usage.output)
                let cacheRead = number(usage.cacheRead)
                let cacheWrite = number(usage.cacheWrite)
                let totalTokens = number(usage.totalTokens)
                let cost = number(usage.cost?.total)
                let messageTimestamp = positiveNumber(message.timestamp)
                let date = messageTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? date(from: entry.timestamp)
                let key = [
                    entry.id ?? "", entry.timestamp?.key ?? "", messageTimestamp.map(canonical) ?? "",
                    message.provider ?? "", message.api ?? "", message.model ?? "",
                    canonical(input), canonical(output), canonical(cacheRead), canonical(cacheWrite),
                    canonical(totalTokens), canonical(cost)
                ].joined(separator: "\u{1f}")
                guard seen.insert(key).inserted else { return true }

                totals.allTimeCost += cost
                if let date, date >= startOfDay, date < nextDay {
                    totals.todayInput += input
                    totals.todayOutput += output
                    totals.todayCacheRead += cacheRead
                    totals.todayCacheWrite += cacheWrite
                    totals.todayCost += cost
                }
                return true
            }
        }
        return totals
    }

    static func sessionRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        if let override = environment["PI_CODING_AGENT_SESSION_DIR"].flatMap(nonEmpty) {
            return try absolutePath(override, home: home)
        }
        let rawAgentDir = environment["PI_CODING_AGENT_DIR"].flatMap(nonEmpty) ?? "~/.pi/agent"
        let agentDir = try absolutePath(rawAgentDir, home: home)
        let settingsPath = (agentDir as NSString).appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let configured = (try? JSONDecoder().decode(Settings.self, from: data).sessionDir).flatMap(nonEmpty) {
            return try absolutePath(configured, home: home)
        }
        return (agentDir as NSString).appendingPathComponent("sessions")
    }

    static func latestSession(cwd: String?,
                              root: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                              now: Date = Date()) -> SessionMetadata? {
        guard let cwd, let resolvedRoot = root ?? (try? sessionRoot(environment: environment, home: home)) else { return nil }
        if let cached = cachedMetadata(root: resolvedRoot, cwd: cwd, now: now) { return cached }
        guard let index = sessionIndex(root: resolvedRoot, now: now), let file = index[cwd] else { return nil }

        var latestName: String?
        var sawSessionInfo = false
        try? forEachEntry(path: file.path) { entry in
            if entry.type == "session_info" {
                sawSessionInfo = true
                latestName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return true
        }
        let title = sawSessionInfo && !(latestName?.isEmpty ?? true) ? latestName : nil
        let metadata = SessionMetadata(path: file.path, title: title, modified: file.modified)
        storeMetadata(metadata, root: resolvedRoot, cwd: cwd)
        return metadata
    }

    private static func cachedMetadata(root: String, cwd: String, now: Date) -> SessionMetadata? {
        indexCache.lock.lock()
        defer { indexCache.lock.unlock() }
        guard let value = indexCache.byRoot[root],
              case let age = now.timeIntervalSince(value.builtAt), age >= 0, age < indexLifetime else { return nil }
        return value.metadataByCWD[cwd]
    }

    private static func sessionIndex(root: String, now: Date) -> [String: IndexedFile]? {
        indexCache.lock.lock()
        if let value = indexCache.byRoot[root],
           case let age = now.timeIntervalSince(value.builtAt), age >= 0, age < indexLifetime {
            indexCache.lock.unlock()
            return value.newestByCWD
        }
        indexCache.nextGeneration &+= 1
        let generation = indexCache.nextGeneration
        indexCache.lock.unlock()

        let rebuildStartedAt = ProcessInfo.processInfo.systemUptime
        guard let files = try? sessionFiles(root: root) else { return nil }
        var newestByCWD: [String: IndexedFile] = [:]
        for path in files {
            guard let header = try? sessionHeader(path: path) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            let candidate = IndexedFile(path: path, modified: modified)
            if let current = newestByCWD[header.cwd],
               (current.modified ?? .distantPast) >= (candidate.modified ?? .distantPast) { continue }
            newestByCWD[header.cwd] = candidate
        }
        let completedAt = now.addingTimeInterval(max(ProcessInfo.processInfo.systemUptime - rebuildStartedAt, 0))

        indexCache.lock.lock()
        if let published = indexCache.byRoot[root], published.generation > generation {
            indexCache.lock.unlock()
            return published.newestByCWD
        }
        indexCache.byRoot[root] = .init(
            generation: generation,
            builtAt: completedAt,
            newestByCWD: newestByCWD,
            metadataByCWD: [:]
        )
        indexCache.lock.unlock()
        return newestByCWD
    }

    private static func storeMetadata(_ metadata: SessionMetadata, root: String, cwd: String) {
        indexCache.lock.lock()
        defer { indexCache.lock.unlock() }
        guard indexCache.byRoot[root]?.newestByCWD[cwd]?.path == metadata.path else { return }
        indexCache.byRoot[root]?.metadataByCWD[cwd] = metadata
    }

    private static func sessionHeader(path: String) throws -> (id: String, cwd: String)? {
        var header: (id: String, cwd: String)?
        try forEachEntry(path: path) { entry in
            guard entry.type == "session", let id = entry.id.flatMap(nonEmpty), let cwd = entry.cwd.flatMap(nonEmpty) else {
                return false
            }
            header = (id, cwd)
            return false
        }
        return header
    }

    private static func sessionFiles(root: String) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalizedErrorMessage("Unable to read Pi session history")
        }
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw LocalizedErrorMessage("Unable to read Pi session history") }
        let files: [String]
        do {
            files = try enumerator.compactMap { item -> String? in
                guard let url = item as? URL, url.pathExtension.lowercased() == "jsonl",
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                return url.path
            }.sorted()
        } catch { throw LocalizedErrorMessage("Unable to read Pi session history") }
        guard !enumerationFailed else { throw LocalizedErrorMessage("Unable to read Pi session history") }
        return files
    }

    // Reads bounded records without repeatedly removing prefixes from a growing buffer.
    // Oversized records are discarded through their newline and never decoded or logged.
    private static func forEachEntry(path: String, _ body: (Entry) -> Bool) throws {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let decoder = JSONDecoder()
            var record = Data()
            var discarding = false
            var shouldContinue = true
            while shouldContinue, let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for byte in chunk {
                    if byte == 0x0A {
                        if !discarding, let entry = try? decoder.decode(Entry.self, from: record) {
                            shouldContinue = body(entry)
                        }
                        record.removeAll(keepingCapacity: true)
                        discarding = false
                        if !shouldContinue { break }
                    } else if !discarding {
                        if record.count < maximumRecordBytes { record.append(byte) }
                        else { record.removeAll(keepingCapacity: true); discarding = true }
                    }
                }
            }
            if shouldContinue, !discarding, !record.isEmpty,
               let entry = try? decoder.decode(Entry.self, from: record) { _ = body(entry) }
        } catch { throw LocalizedErrorMessage("Unable to read a Pi session file") }
    }

    private static func number(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    private static func positiveNumber(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func date(from timestamp: Timestamp?) -> Date? {
        guard let timestamp else { return nil }
        switch timestamp {
        case .milliseconds(let value):
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value / 1000)
        case .iso8601(let raw):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
    }

    private static func canonical(_ value: Double) -> String { String(format: "%.17g", value) }
    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

    private static func absolutePath(_ raw: String, home: String) throws -> String {
        let expanded: String
        if raw == "~" { expanded = home }
        else if raw.hasPrefix("~/") { expanded = home + raw.dropFirst() }
        else { expanded = raw }
        guard expanded.hasPrefix("/") else {
            throw LocalizedErrorMessage("Pi session directory must be absolute, exactly ~, or begin with ~/")
        }
        return (expanded as NSString).standardizingPath
    }
}
