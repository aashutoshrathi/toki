import Foundation

// Plain value type shared across the app; only the generation lives behind macOS 26.
struct UsageInsight: Equatable {
    var summary: String
    var suggestions: [UsageSuggestion]
}

struct UsageSuggestion: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var severity: RecommendationSeverity
}
