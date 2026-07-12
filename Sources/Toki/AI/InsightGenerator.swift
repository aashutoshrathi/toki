import Foundation

// Default on-device AI prompt. Declared outside the FoundationModels guard so the Settings
// editor can reference it as placeholder text without depending on the gated enum.
let defaultAIInstructions = """
    You summarize a developer's AI coding-tool usage for a menu bar app. Be concise \
    and specific. Only restate and interpret the facts you are given - never invent \
    quota numbers, account names, or reset times.
    """

// On-device usage insights via Apple's Foundation Models. The module only exists in the
// macOS 26 SDK, so `canImport` keeps this file compiling on older SDKs (e.g. CI runners),
// and `@available` keeps FoundationModels unlinked at runtime on older systems.
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
enum InsightGenerator {
    @Generable
    struct GeneratedInsight {
        @Guide(description: "One natural, specific sentence summarizing the user's coding usage across accounts")
        let summary: String
        @Guide(description: "Up to 3 short, actionable suggestions", .count(3))
        let suggestions: [GeneratedSuggestion]
    }

    @Generable
    struct GeneratedSuggestion {
        @Guide(description: "A short actionable tip, one line")
        let text: String
        @Guide(description: "How urgent: good, warning, critical, or neutral")
        let severity: String
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // Returns nil when the model is unavailable or generation fails - callers keep the
    // deterministic recommendation on screen. The rule-based recommendation is passed in
    // as grounding so the model only phrases the facts, never invents numbers.
    static func generate(snapshots: [AccountSnapshot], grounding: SmartRecommendation, instructions customInstructions: String? = nil) async -> UsageInsight? {
        guard isAvailable else { return nil }

        let resolved = customInstructions.flatMap { $0.isEmpty ? nil : $0 } ?? defaultInstructions
        let session = LanguageModelSession(instructions: resolved)
        do {
            let response = try await session.respond(
                to: prompt(snapshots: snapshots, grounding: grounding),
                generating: GeneratedInsight.self
            )
            let content = response.content
            return UsageInsight(
                summary: content.summary,
                suggestions: content.suggestions.map {
                    UsageSuggestion(text: $0.text, severity: severity(from: $0.severity))
                }
            )
        } catch {
            DiagnosticLogger.shared.record(.warning, component: "ai", code: "insight_failed", detail: diagnosticErrorDetail(error))
            return nil
        }
    }

    static let defaultInstructions = defaultAIInstructions

    // Pure function - unit-testable without the model.
    static func prompt(snapshots: [AccountSnapshot], grounding: SmartRecommendation) -> String {
        var lines: [String] = []
        lines.append("Recommendation: \(grounding.title) - \(grounding.detail)")
        lines.append("Accounts (percentages are quota REMAINING, higher is better):")
        for snapshot in snapshots where !snapshot.isError {
            let status = snapshot.remainingRatio.map { "\(percentText($0)) remaining" } ?? snapshot.primary
            lines.append("- \(snapshot.name) [\(snapshot.provider.displayName)]: \(status)")
        }
        lines.append("Summarize the current situation in one sentence and give up to 3 suggestions.")
        return lines.joined(separator: "\n")
    }

    private static func severity(from raw: String) -> RecommendationSeverity {
        switch raw.lowercased() {
        case "good": return .good
        case "warning": return .warning
        case "critical": return .critical
        default: return .neutral
        }
    }
}
#endif
