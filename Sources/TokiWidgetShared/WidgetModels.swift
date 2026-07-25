import Foundation
import Darwin

public let tokiAppGroupIdentifier = "group.com.aashutoshrathi.toki"
public let tokiWidgetKind = "com.aashutoshrathi.toki.widget"
public let tokiQuotaRingsWidgetKind = "com.aashutoshrathi.toki.quota-rings"
public let tokiWidgetDataFilename = "widget-data.json"
public let tokiWidgetDataModeInfoKey = "TokiWidgetDataMode"

public func tokiUsesLocalWidgetData(bundle: Bundle = .main) -> Bool {
    bundle.object(forInfoDictionaryKey: tokiWidgetDataModeInfoKey) as? String == "local"
}

public func tokiUserHomeDirectoryURL() -> URL? {
    guard let user = getpwuid(getuid()), let home = user.pointee.pw_dir else {
        return nil
    }
    return URL(fileURLWithPath: String(cString: home), isDirectory: true)
}

public func tokiLocalWidgetDataURL(userHomeDirectory: URL? = tokiUserHomeDirectoryURL()) -> URL? {
    userHomeDirectory?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Toki", isDirectory: true)
        .appendingPathComponent(tokiWidgetDataFilename)
}

public struct WidgetDataSnapshot: Codable, Sendable {
    public var updatedAt: Date
    public var entries: [WidgetEntry]
    public var awaitingInputCount: Int
    public var allExhausted: Bool
    public var breakSuggestion: String?

    public init(
        updatedAt: Date,
        entries: [WidgetEntry],
        awaitingInputCount: Int,
        allExhausted: Bool,
        breakSuggestion: String?
    ) {
        self.updatedAt = updatedAt
        self.entries = entries
        self.awaitingInputCount = awaitingInputCount
        self.allExhausted = allExhausted
        self.breakSuggestion = breakSuggestion
    }

    public func isStale(at date: Date = Date(), maxAge: TimeInterval = 5 * 60) -> Bool {
        date.timeIntervalSince(updatedAt) > maxAge
    }
}

public struct WidgetEntry: Codable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var displayName: String
    public var value: String
    public var remainingRatio: Double?
    public var leadingText: String?
    public var colorHex: String?

    public init(
        id: String,
        provider: String,
        displayName: String,
        value: String,
        remainingRatio: Double?,
        leadingText: String?,
        colorHex: String?
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.value = value
        self.remainingRatio = remainingRatio
        self.leadingText = leadingText
        self.colorHex = colorHex
    }
}
