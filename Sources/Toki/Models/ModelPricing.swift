import Foundation

// Published per-million-token list prices, used to turn the token counts recorded in local
// session files into a dollar estimate. Providers don't write a cost figure into those files,
// so the only way to show spend for a Claude Code session is to price the tokens ourselves.
//
// Cache tokens are priced separately and are NOT a rounding error - a long agent session is
// mostly cache reads, and pricing them at the full input rate overstates cost by an order of
// magnitude. The multipliers are provider-published: a cache write costs 1.25x the base input
// rate (the 5-minute TTL, which is what Claude Code uses), a cache read 0.1x.
struct ModelRate {
    /// USD per million input tokens.
    let input: Double
    /// USD per million output tokens.
    let output: Double

    var cacheWrite: Double { input * 1.25 }
    var cacheRead: Double { input * 0.1 }
}

enum ModelPricing {
    // Matched by longest prefix so that a dated or suffixed variant ("claude-opus-4-8-20260101")
    // resolves to its base model rather than falling through to nil.
    private static let rates: [(prefix: String, rate: ModelRate)] = [
        ("claude-fable-5", ModelRate(input: 10, output: 50)),
        ("claude-mythos-5", ModelRate(input: 10, output: 50)),
        ("claude-opus-4-8", ModelRate(input: 5, output: 25)),
        ("claude-opus-4-7", ModelRate(input: 5, output: 25)),
        ("claude-opus-4-6", ModelRate(input: 5, output: 25)),
        ("claude-opus-4-5", ModelRate(input: 5, output: 25)),
        ("claude-opus-4", ModelRate(input: 15, output: 75)),
        ("claude-sonnet-5", ModelRate(input: 3, output: 15)),
        ("claude-sonnet-4-6", ModelRate(input: 3, output: 15)),
        ("claude-sonnet-4-5", ModelRate(input: 3, output: 15)),
        ("claude-sonnet-4", ModelRate(input: 3, output: 15)),
        ("claude-haiku-4-5", ModelRate(input: 1, output: 5)),
        ("claude-3-5-haiku", ModelRate(input: 0.8, output: 4)),
    ]

    static func rate(forModel model: String) -> ModelRate? {
        let normalized = model.lowercased()
        // Longest prefix wins - "claude-opus-4-8" must beat the shorter "claude-opus-4".
        return rates
            .filter { normalized.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .rate
    }

    // Returns nil for an unrecognized model rather than guessing: a wrong price is worse than
    // no price, and a silently-wrong dollar figure is exactly the kind of number people act on.
    static func costUSD(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheWriteTokens: Int,
        cacheReadTokens: Int
    ) -> Double? {
        guard let rate = rate(forModel: model) else { return nil }
        let millions = 1_000_000.0
        return Double(inputTokens) / millions * rate.input
            + Double(outputTokens) / millions * rate.output
            + Double(cacheWriteTokens) / millions * rate.cacheWrite
            + Double(cacheReadTokens) / millions * rate.cacheRead
    }
}
