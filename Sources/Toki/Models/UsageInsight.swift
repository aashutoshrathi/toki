import Foundation

// Plain value type shared across the app; only the generation lives behind macOS 26.
struct UsageInsight: Equatable {
    var summary: String
    var suggestions: [UsageSuggestion]
}

struct UsageSuggestion: Identifiable, Equatable {
    var text: String
    var severity: RecommendationSeverity

    // Derive identity from content so regenerating an unchanged suggestion keeps the
    // same SwiftUI row identity instead of churning as a brand-new item every refresh.
    var id: String { "\(severity)-\(text)" }
}
