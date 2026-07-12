import Foundation

enum Provider: String, Codable, Sendable {
    case openai
    case codex
    case anthropic
    case chatgpt
    case claude
    case claudeCode
    case copilot
    case openCode
    case manual

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .codex: return "Codex"
        case .anthropic: return "Anthropic"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code"
        case .copilot: return "Copilot"
        case .openCode: return "OpenCode"
        case .manual: return "Manual"
        }
    }

    var isConsumerTracked: Bool {
        switch self {
        case .chatgpt, .claude, .manual: return true
        case .openai, .codex, .anthropic, .claudeCode, .copilot, .openCode: return false
        }
    }

    var isClaudeAccount: Bool {
        self == .claudeCode || self == .claude
    }
}
