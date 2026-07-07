import Foundation

enum Provider: String, Codable {
    case openai
    case codex
    case anthropic
    case chatgpt
    case claude
    case claudeCode
    case manual

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .codex: return "Codex"
        case .anthropic: return "Anthropic"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code"
        case .manual: return "Manual"
        }
    }

    var isConsumerTracked: Bool {
        switch self {
        case .chatgpt, .claude, .manual: return true
        case .openai, .codex, .anthropic, .claudeCode: return false
        }
    }

    var isClaudeAccount: Bool {
        self == .claudeCode || self == .claude
    }
}
