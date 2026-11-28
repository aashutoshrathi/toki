namespace Toki.Core.Tests;

internal static class DesktopFeatureTests {
    internal static void Run() {
        TestHarness.Run("privacy masks details and errors without changing quotas or source data", () => {
            var source = new ProviderSnapshot("codex", "Codex", "private@example.test", [new QuotaWindow("5h", 25, null)], "Error in private account", DateTimeOffset.UtcNow);
            var display = PrivacyDisplay.Snapshot(source, true);
            TestHarness.Equal("Account details hidden", display.Detail);
            TestHarness.True(!display.Error!.Contains("private"), "error text must be masked");
            TestHarness.Equal(75.0, display.Windows[0].RemainingPercent);
            TestHarness.Equal("private@example.test", source.Detail);
            TestHarness.Equal(source, PrivacyDisplay.Snapshot(source, false));
        });
        TestHarness.Run("privacy preserves successful provider state", () => {
            var source = new ProviderSnapshot("codex", "Codex", "pro", [], null, DateTimeOffset.UtcNow);
            TestHarness.Equal<string?>(null, PrivacyDisplay.Snapshot(source, true).Error);
        });
        TestHarness.Run("legacy settings keep privacy off and new settings persist it", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "settings.json");
            File.WriteAllText(path, "{\"doNotDisturb\":true}");
            var old = SettingsStore.LoadFrom(path);
            TestHarness.True(old.DoNotDisturb && !old.HideSensitiveInfo, "old settings should retain their meaning");
            SettingsStore.SaveTo(path, old with { HideSensitiveInfo = true });
            TestHarness.True(SettingsStore.LoadFrom(path).HideSensitiveInfo, "privacy must survive restart");
        });
        TestHarness.Run("session search combines words project and provider and preserves order", () => {
            LocalSession[] sessions = [
                new(1, "claude", "Fix parser", "one.jsonl", @"C:\project", DateTimeOffset.UtcNow),
                new(2, "codex", "Fix parser", "two.jsonl", @"C:\project", DateTimeOffset.UtcNow),
                new(3, "codex", "Ship UI", "three.jsonl", null, DateTimeOffset.UtcNow)
            ];
            var filtered = SessionFilter.Apply(sessions, "codex", " PARSER  PROJECT ");
            TestHarness.Equal(1, filtered.Count);
            TestHarness.Equal(2L, filtered[0].Id);
            TestHarness.Equal("1,2,3", string.Join(",", SessionFilter.Apply(sessions, null, "").Select(s => s.Id)));
            TestHarness.Equal(0, SessionFilter.Apply(sessions, "claude", "UI").Count);
        });
    }
}
