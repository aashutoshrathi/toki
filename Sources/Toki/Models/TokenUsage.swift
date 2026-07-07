import Foundation

struct TokenUsage {
    var inputTokens: Double
    var outputTokens: Double
    var totalTokens: Double { inputTokens + outputTokens }

    static func fromOpenAI(_ json: Any) -> TokenUsage {
        let input = sumNumbers(in: json, keys: [
            "input_tokens",
            "input_audio_tokens"
        ])
        let output = sumNumbers(in: json, keys: [
            "output_tokens",
            "output_audio_tokens"
        ])
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    static func fromAnthropic(_ json: Any) -> TokenUsage {
        let detailedInput = sumNumbers(in: json, keys: [
            "uncached_input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens"
        ])
        let input = detailedInput > 0 ? detailedInput : sumNumbers(in: json, keys: ["input_tokens"])
        let output = sumNumbers(in: json, keys: ["output_tokens"])
        return TokenUsage(inputTokens: input, outputTokens: output)
    }
}
