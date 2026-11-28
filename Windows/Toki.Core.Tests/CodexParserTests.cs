using System.Text.Json;
using Toki.Core.Codex;

namespace Toki.Core.Tests;

internal static class CodexParserTests {
    internal static void Run() {
        TestHarness.Run("codex parser reads primary and secondary windows", () => {
            using var document = JsonDocument.Parse(
                "{\"rateLimitsByLimitId\":{\"codex\":{\"planType\":\"pro\",\"primary\":{\"usedPercent\":0,\"resetsAt\":1893456000,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":100,\"resetsAt\":1893542400,\"windowDurationMins\":10080}}}}");
            var parsed = CodexUsageParser.Parse(document.RootElement, null);
            TestHarness.Equal(2, parsed.Windows.Count);
            TestHarness.Equal("5h", parsed.Windows[0].Label);
            TestHarness.Equal(100.0, parsed.Windows[0].RemainingPercent);
            TestHarness.Equal("7d", parsed.Windows[1].Label);
            TestHarness.Equal(0.0, parsed.Windows[1].RemainingPercent);
            TestHarness.Equal("OpenAI Codex - pro", parsed.Detail);
            TestHarness.True(parsed.Windows[0].ResetsAt is not null, "reset should parse");
        });

        TestHarness.Run("codex parser orders reversed provider slots by quota duration", () => {
            using var document = JsonDocument.Parse("""
                {"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1893542400},
                               "secondary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1893456000}}}
                """);
            var parsed = CodexUsageParser.Parse(document.RootElement, null);
            TestHarness.Equal(2, parsed.Windows.Count);
            TestHarness.Equal("5h", parsed.Windows[0].Label);
            TestHarness.Equal(80.0, parsed.Windows[0].RemainingPercent);
            TestHarness.Equal(DateTimeOffset.FromUnixTimeSeconds(1893456000), parsed.Windows[0].ResetsAt!.Value);
            TestHarness.Equal("7d", parsed.Windows[1].Label);
            TestHarness.Equal(60.0, parsed.Windows[1].RemainingPercent);
            TestHarness.Equal(DateTimeOffset.FromUnixTimeSeconds(1893542400), parsed.Windows[1].ResetsAt!.Value);
        });

        TestHarness.Run("codex parser falls back to rateLimits object", () => {
            using var document = JsonDocument.Parse(
                "{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":300}}}");
            var parsed = CodexUsageParser.Parse(document.RootElement, null);
            TestHarness.Equal(1, parsed.Windows.Count);
            TestHarness.Equal(75.0, parsed.Windows[0].RemainingPercent);
        });

        TestHarness.Run("codex parser skips missing usedPercent", () => {
            using var document = JsonDocument.Parse(
                "{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":10}}}");
            var parsed = CodexUsageParser.Parse(document.RootElement, null);
            TestHarness.Equal(1, parsed.Windows.Count);
            TestHarness.Equal("7d", parsed.Windows[0].Label);
        });

        TestHarness.Run("codex parser clamps utilization", () => {
            using var document = JsonDocument.Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":140}}}");
            var parsed = CodexUsageParser.Parse(document.RootElement, null);
            TestHarness.Equal(100.0, parsed.Windows[0].UsedPercent);
        });

        TestHarness.Run("codex parser uses account email when plan is absent", () => {
            using var rateLimits = JsonDocument.Parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":5}}}");
            using var account = JsonDocument.Parse("{\"account\":{\"type\":\"chatgpt\",\"email\":\"tester@example.com\"}}");
            var parsed = CodexUsageParser.Parse(rateLimits.RootElement, account.RootElement);
            TestHarness.Equal("tester@example.com", parsed.Detail);
        });

        TestHarness.Run("codex parser rejects empty rate limits", () => {
            using var document = JsonDocument.Parse("{\"rateLimits\":{}}");
            TestHarness.Throws<ProviderException>(
                () => CodexUsageParser.Parse(document.RootElement, null),
                "unavailable");
        });

        TestHarness.Run("codex parser rejects missing rate limits", () => {
            TestHarness.Throws<ProviderException>(() => CodexUsageParser.Parse(null, null), "unavailable");
        });

        TestHarness.Run("codex parser derives labels from duration", () => {
            using var document = JsonDocument.Parse(
                "{\"rateLimits\":{\"primary\":{\"usedPercent\":1,\"windowDurationMins\":60},\"secondary\":{\"usedPercent\":1,\"windowDurationMins\":2880}}}");
            var parsed = CodexUsageParser.Parse(document.RootElement, null);
            TestHarness.Equal("1h", parsed.Windows[0].Label);
            TestHarness.Equal("2d", parsed.Windows[1].Label);
        });
    }
}
