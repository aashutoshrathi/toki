import Foundation

struct SmartRecommendation: Equatable {
    var title: String
    var detail: String
    var accountID: String?
    var switchTarget: String?
    var switchCommand: String?
    var severity: RecommendationSeverity
}

enum RecommendationSeverity: Equatable {
    case good
    case warning
    case critical
    case neutral
}
