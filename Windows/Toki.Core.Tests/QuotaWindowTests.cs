namespace Toki.Core.Tests;

internal static class QuotaWindowTests {
    internal static void Run() {
        TestHarness.Run("quota window reports full remaining at zero used", () => {
            var window = new QuotaWindow("5h", 0, null);
            TestHarness.Equal(100.0, window.RemainingPercent);
        });

        TestHarness.Run("quota window reports zero remaining at full used", () => {
            var window = new QuotaWindow("5h", 100, null);
            TestHarness.Equal(0.0, window.RemainingPercent);
        });

        TestHarness.Run("quota window clamps out-of-range utilization", () => {
            TestHarness.Equal(0.0, new QuotaWindow("5h", 140, null).RemainingPercent);
            TestHarness.Equal(100.0, new QuotaWindow("5h", -20, null).RemainingPercent);
        });

        TestHarness.Run("quota window keeps reset timestamp", () => {
            var reset = DateTimeOffset.FromUnixTimeSeconds(1893456000);
            TestHarness.Equal(reset, new QuotaWindow("7d", 42, reset).ResetsAt);
        });
    }
}
