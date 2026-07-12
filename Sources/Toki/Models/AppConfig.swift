import Foundation

struct AppConfig: Codable {
    var refreshMinutes: Int?
    var accountLabels: [AccountLabelConfig]?
    var accounts: [AccountConfig]
    var aiInstructions: String?
}

struct AccountLabelConfig: Codable {
    var email: String
    var organizationUuid: String?
    var organizationName: String?
    var nickname: String?
    var emoji: String?
    var color: String?
}

// On disk the flat shape is { "label", "type", ...optional fields }. Internally the
// properties keep their original names (id/name/provider) so the rest of the app is
// untouched; only the JSON key mapping changed. Decoding accepts the old shape
// (id/name/provider) too, so existing configs load and can be migrated forward.
struct AccountConfig: Codable, Identifiable {
    var id: String
    var name: String
    var provider: Provider
    var apiKey: String?
    var apiKeyEnv: String?
    var apiKeyCommand: String?
    var dailyTokenBudget: Double?
    var monthlyUsdBudget: Double?
    var limitLabel: String?
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var resetsAt: String?
    var resetEveryHours: Double?
    var resetAnchor: String?
    var claudeSwapCommand: String?
    var codexAuthPath: String?
    var notes: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case label, name
        case type, provider
        case apiKey, apiKeyEnv, apiKeyCommand
        case dailyTokenBudget, monthlyUsdBudget, limitLabel
        case used, limit, remaining
        case resetsAt, resetEveryHours, resetAnchor
        case claudeSwapCommand, codexAuthPath, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // New key "label" (fallback to legacy "name"); must be non-empty.
        guard let label = try (c.decodeIfPresent(String.self, forKey: .label)
            ?? c.decodeIfPresent(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.label, .init(codingPath: decoder.codingPath, debugDescription: "account needs a non-empty label"))
        }
        name = label
        // New key "type" (fallback to legacy "provider").
        guard let type = try c.decodeIfPresent(Provider.self, forKey: .type)
            ?? c.decodeIfPresent(Provider.self, forKey: .provider) else {
            throw DecodingError.keyNotFound(CodingKeys.type, .init(codingPath: decoder.codingPath, debugDescription: "account needs a type"))
        }
        provider = type
        // id is optional now; derive a stable slug from label + type when absent.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? AccountConfig.slug(label: label, provider: type)

        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        apiKeyCommand = try c.decodeIfPresent(String.self, forKey: .apiKeyCommand)
        dailyTokenBudget = try c.decodeIfPresent(Double.self, forKey: .dailyTokenBudget)
        monthlyUsdBudget = try c.decodeIfPresent(Double.self, forKey: .monthlyUsdBudget)
        limitLabel = try c.decodeIfPresent(String.self, forKey: .limitLabel)
        used = try c.decodeIfPresent(Double.self, forKey: .used)
        limit = try c.decodeIfPresent(Double.self, forKey: .limit)
        remaining = try c.decodeIfPresent(Double.self, forKey: .remaining)
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        resetEveryHours = try c.decodeIfPresent(Double.self, forKey: .resetEveryHours)
        resetAnchor = try c.decodeIfPresent(String.self, forKey: .resetAnchor)
        claudeSwapCommand = try c.decodeIfPresent(String.self, forKey: .claudeSwapCommand)
        codexAuthPath = try c.decodeIfPresent(String.self, forKey: .codexAuthPath)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .label)
        try c.encode(provider, forKey: .type)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(apiKeyEnv, forKey: .apiKeyEnv)
        try c.encodeIfPresent(apiKeyCommand, forKey: .apiKeyCommand)
        try c.encodeIfPresent(dailyTokenBudget, forKey: .dailyTokenBudget)
        try c.encodeIfPresent(monthlyUsdBudget, forKey: .monthlyUsdBudget)
        try c.encodeIfPresent(limitLabel, forKey: .limitLabel)
        try c.encodeIfPresent(used, forKey: .used)
        try c.encodeIfPresent(limit, forKey: .limit)
        try c.encodeIfPresent(remaining, forKey: .remaining)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encodeIfPresent(resetEveryHours, forKey: .resetEveryHours)
        try c.encodeIfPresent(resetAnchor, forKey: .resetAnchor)
        try c.encodeIfPresent(claudeSwapCommand, forKey: .claudeSwapCommand)
        try c.encodeIfPresent(codexAuthPath, forKey: .codexAuthPath)
        try c.encodeIfPresent(notes, forKey: .notes)
    }

    init(id: String, name: String, provider: Provider) {
        self.id = id
        self.name = name
        self.provider = provider
    }

    // Derives an id from the label and provider. Two labels that normalize to the same base
    // (e.g. "Work!" and "Work") get distinct ids via a short suffix of a STABLE hash of raw
    // label+provider, so same-label-different-provider accounts never collide and the id is
    // the same across launches (Swift's Hashable is per-run randomized, can't be used here).
    private static func slug(label: String, provider: Provider) -> String {
        let base = label.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let root = base.isEmpty ? provider.rawValue : base
        // FNV-1a over raw label + provider rawValue - deterministic across processes.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (label + ":" + provider.rawValue).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(root)-\(String(format: "%x", hash % 1_000_000))"
    }
}
