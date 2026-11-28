using Toki.Core.Claude;

namespace Toki.Core.Tests;

internal static class ClaudeUsageParserTests {
    internal static void Run() {
        TestHarness.Run("claude usage parses 0 and 100 percent", () => {
            var usage = ClaudeUsageParser.Parse(
                "{\"five_hour\":{\"utilization\":0,\"resets_at\":\"2030-01-01T00:00:00Z\"},\"seven_day\":{\"utilization\":100}}");
            TestHarness.Equal(2, usage.Windows.Count);
            TestHarness.Equal("5h", usage.Windows[0].Label);
            TestHarness.Equal(100.0, usage.Windows[0].RemainingPercent);
            TestHarness.Equal("7d", usage.Windows[1].Label);
            TestHarness.Equal(0.0, usage.Windows[1].RemainingPercent);
            TestHarness.True(usage.Windows[0].ResetsAt is not null, "reset should parse");
        });

        TestHarness.Run("claude usage skips null utilization", () => {
            var usage = ClaudeUsageParser.Parse(
                "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":42}}");
            TestHarness.Equal(1, usage.Windows.Count);
            TestHarness.Equal("7d", usage.Windows[0].Label);
        });

        TestHarness.Run("claude usage clamps out-of-range utilization", () => {
            var usage = ClaudeUsageParser.Parse("{\"five_hour\":{\"utilization\":140}}");
            TestHarness.Equal(100.0, usage.Windows[0].UsedPercent);
        });

        TestHarness.Run("claude usage parses scoped model windows", () => {
            var usage = ClaudeUsageParser.Parse(
                "{\"seven_day\":{\"utilization\":10},\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":55,\"scope\":{\"model\":{\"display_name\":\"Fable 5\"}}},{\"kind\":\"weekly_all\",\"percent\":90}]}");
            TestHarness.Equal(2, usage.Windows.Count);
            TestHarness.Equal("Fable 5 7d", usage.Windows[1].Label);
            TestHarness.Equal(55.0, usage.Windows[1].UsedPercent);
        });

        TestHarness.Run("claude usage rejects malformed json", () => {
            TestHarness.Throws<ProviderException>(() => ClaudeUsageParser.Parse("nope"), "not valid JSON");
        });

        TestHarness.Run("claude usage rejects empty payload", () => {
            TestHarness.Throws<ProviderException>(() => ClaudeUsageParser.Parse("{}"), "unavailable");
        });

        TestHarness.Run("claude usage rejects non-object payload", () => {
            TestHarness.Throws<ProviderException>(() => ClaudeUsageParser.Parse("[]"), "not a JSON object");
        });
    }
}
