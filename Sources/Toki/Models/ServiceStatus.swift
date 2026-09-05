import Foundation

/// How healthy a provider's own service is, independent of whether Toki can read its usage.
///
/// The cases are the five component states a Statuspage exposes, collapsed to what a user needs
/// to decide whether to keep working: everything is fine, it is slow, part of it is down, or it
/// is down. `severity` is the ordering used to pick one level for a provider whose service spans
/// several components.
enum ServiceStatusLevel: String, Sendable, Hashable, Comparable {
    case operational
    case maintenance
    case degraded
    case partialOutage
    case majorOutage

    /// Statuspage's per-component state, e.g. `"degraded_performance"`.
    init?(componentStatus: String) {
        switch componentStatus {
        case "operational": self = .operational
        case "under_maintenance": self = .maintenance
        case "degraded_performance": self = .degraded
        case "partial_outage": self = .partialOutage
        case "major_outage": self = .majorOutage
        default: return nil
        }
    }

    /// Statuspage's whole-page roll-up, e.g. `"minor"`. Used for a provider the page does not
    /// break out into a component of its own.
    init?(pageIndicator: String) {
        switch pageIndicator {
        case "none": self = .operational
        case "maintenance": self = .maintenance
        case "minor": self = .degraded
        case "major": self = .partialOutage
        case "critical": self = .majorOutage
        default: return nil
        }
    }

    /// Maintenance sorts below degraded: it is planned, so a real fault reported by any other
    /// component of the same provider is the one worth surfacing.
    var severity: Int {
        switch self {
        case .operational: return 0
        case .maintenance: return 1
        case .degraded: return 2
        case .partialOutage: return 3
        case .majorOutage: return 4
        }
    }

    static func < (lhs: ServiceStatusLevel, rhs: ServiceStatusLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    var isDisrupted: Bool { self != .operational }

    var label: String {
        switch self {
        case .operational: return "Operational"
        case .maintenance: return "Maintenance"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .majorOutage: return "Outage"
        }
    }

    /// Reads as a sentence after a provider name, for an event title.
    var eventPhrase: String {
        switch self {
        case .operational: return "is operational"
        case .maintenance: return "is under maintenance"
        case .degraded: return "is degraded"
        case .partialOutage: return "is partly down"
        case .majorOutage: return "is down"
        }
    }
}

/// A provider's service health as of the last check, with the components that caused it.
struct ServiceStatus: Hashable, Sendable, Identifiable {
    var provider: Provider
    var level: ServiceStatusLevel
    /// What the status page calls the current state, e.g. "All Systems Operational".
    var pageDescription: String
    /// Names of this provider's components that are not operational, most severe first.
    var affectedComponents: [String]
    var pageURL: URL
    var checkedAt: Date

    var id: String { provider.rawValue }

    /// One line for a tooltip or a card row: the affected components when the page names them,
    /// falling back to the page's own wording.
    var detail: String {
        guard !affectedComponents.isEmpty else { return pageDescription }
        return affectedComponents.joined(separator: ", ")
    }
}

/// A Statuspage instance and the components on it that belong to each provider Toki tracks.
///
/// Matching is by lowercased prefix rather than exact name because these pages rename components
/// freely (Anthropic's page moved to status.claude.com and renamed every component with it). A
/// prefix also collapses a family in one entry: "codex" covers Codex API, Codex Web and Codex in
/// ChatGPT Desktop, which is what a Codex CLI user means by "is Codex up".
struct ServiceStatusSource: Sendable {
    var id: String
    var pageURL: URL
    var componentPrefixes: [Provider: [String]]

    var summaryURL: URL {
        pageURL.appendingPathComponent("api/v2/summary.json")
    }

    var providers: [Provider] { Array(componentPrefixes.keys) }

    static let all: [ServiceStatusSource] = [claude, openai, github, cursor]

    static let claude = ServiceStatusSource(
        id: "claude",
        pageURL: URL(string: "https://status.claude.com")!,
        componentPrefixes: [
            .claudeCode: ["claude code"],
            .claude: ["claude.ai"],
            .anthropic: ["claude api"]
        ]
    )

    static let openai = ServiceStatusSource(
        id: "openai",
        pageURL: URL(string: "https://status.openai.com")!,
        componentPrefixes: [
            .codex: ["codex"],
            .openai: ["chat completions", "responses"],
            // The page has no ChatGPT component of its own, so a consumer account falls back to
            // the whole-page roll-up rather than reporting on an API surface it never touches.
            .chatgpt: []
        ]
    )

    static let github = ServiceStatusSource(
        id: "github",
        pageURL: URL(string: "https://www.githubstatus.com")!,
        componentPrefixes: [
            .copilot: ["copilot"]
        ]
    )

    static let cursor = ServiceStatusSource(
        id: "cursor",
        pageURL: URL(string: "https://status.cursor.com")!,
        componentPrefixes: [
            .cursor: ["cli", "ide", "cloud agents"]
        ]
    )

    /// The sources that can say anything about these providers, so a check only calls the pages
    /// whose answer someone is actually going to see.
    static func sources(covering providers: Set<Provider>) -> [ServiceStatusSource] {
        all.filter { source in
            source.componentPrefixes.keys.contains(where: providers.contains)
        }
    }
}
