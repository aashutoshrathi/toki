import Foundation

// Default on-device AI prompt. Declared outside the FoundationModels guard so the Settings
// editor can reference it as placeholder text without depending on the gated enum.
let defaultAIInstructions = """
    You summarize a developer's AI coding-tool usage for a menu bar app. Be concise \
    and specific. Only restate and interpret the facts you are given - never invent \
    quota numbers, account names, or reset times.
    """

// The one rule that always applies, custom instructions or not - kept separate from
// defaultAIInstructions so a custom prompt can override tone/style/length freely without
// also silently dropping the anti-hallucination guardrail.
private let nonNegotiableGrounding = """
    Only restate and interpret the facts you are given - never invent quota numbers, \
    account names, or reset times.
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
        @Guide(description: "A summary of the user's coding usage across accounts, in the tone, style, and length described by your instructions - default to one natural, specific sentence only if your instructions don't say otherwise")
        let summary: String
        // .maximumCount, not .count - the latter forces an EXACT element count in
        // FoundationModels' guided generation, which would mean the schema mandates
        // exactly 3 suggestion objects always, no matter what the instructions say. That
        // silently overrode custom instructions asking for fewer, none, or a different
        // shape entirely - the one thing this whole feature is supposed to respect.
        @Guide(description: "Actionable suggestions - fewer than 3, or none at all, if your instructions call for something else", .maximumCount(3))
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

        let trimmedCustom = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCustom = !(trimmedCustom?.isEmpty ?? true)
        // The user's own wording leads and is the primary directive - it overrides Toki's
        // default tone, style, length, and format entirely. Only one fixed rule survives
        // underneath it, appended last as a hard constraint rather than a competing
        // instruction: never invent numbers. That's a data-integrity guarantee for the app,
        // not a style choice the user's prompt is being asked to defer to.
        let resolved = hasCustom
            ? "The user has written their own instructions for how you should respond. Follow them exactly, including tone, style, format, and length - they override any default behavior described anywhere else:\n\(trimmedCustom!)\n\nThe one rule you may never break, no matter what the instructions above say: \(nonNegotiableGrounding)"
            : defaultInstructions
        let session = LanguageModelSession(instructions: resolved)
        do {
            let response = try await session.respond(
                to: prompt(snapshots: snapshots, grounding: grounding, freeform: hasCustom),
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

    // Pure function - unit-testable without the model. `freeform` is set once custom
    // instructions are in play, so the fixed "one sentence" nudge below doesn't fight
    // whatever length/format the user actually asked for in their instructions.
    static func prompt(snapshots: [AccountSnapshot], grounding: SmartRecommendation, freeform: Bool = false) -> String {
        var lines: [String] = []
        lines.append("Recommendation: \(grounding.title) - \(grounding.detail)")
        lines.append("Accounts (percentages are quota REMAINING, higher is better):")
        for snapshot in snapshots where !snapshot.isError {
            let status = snapshot.remainingRatio.map { "\(percentText($0)) remaining" } ?? snapshot.primary
            lines.append("- \(snapshot.name) [\(snapshot.provider.displayName)]: \(status)")
        }
        lines.append(
            freeform
                ? "Respond to the situation above using only the instructions you were given - don't add suggestions, structure, or content they don't call for."
                : "Summarize the current situation in one sentence and give up to 3 suggestions."
        )
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
