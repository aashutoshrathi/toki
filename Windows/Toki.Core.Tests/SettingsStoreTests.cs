namespace Toki.Core.Tests;

internal static class SettingsStoreTests {
    internal static void Run() {
        TestHarness.Run("settings load missing file returns defaults", () => {
            using var temp = new TempDirectory();
            var settings = SettingsStore.LoadFrom(Path.Combine(temp.Path, "windows-settings.json"));
            TestHarness.Equal<AppSettings>(new AppSettings(), settings);
            TestHarness.True(settings.NotificationsEnabled, "notifications should default on");
            TestHarness.True(!settings.DoNotDisturb, "do not disturb should default off");
        });

        TestHarness.Run("settings round-trip", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "nested", "windows-settings.json");
            var saved = new AppSettings("/claude", "/codex", "/codex/codex.exe", false, true);
            SettingsStore.SaveTo(path, saved);
            TestHarness.Equal(saved, SettingsStore.LoadFrom(path));
        });

        TestHarness.Run("settings save normalizes blank overrides", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "windows-settings.json");
            SettingsStore.SaveTo(path, new AppSettings("   ", "", null, true, false));
            var loaded = SettingsStore.LoadFrom(path);
            TestHarness.Equal<string?>(null, loaded.ClaudeConfigDirectory);
            TestHarness.Equal<string?>(null, loaded.CodexHome);
            TestHarness.Equal<string?>(null, loaded.CodexExecutable);
        });

        TestHarness.Run("settings corrupt file throws and is not overwritten", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "windows-settings.json");
            File.WriteAllText(path, "{ this is not json");
            TestHarness.Throws<SettingsException>(() => SettingsStore.LoadFrom(path), "not valid JSON");
            TestHarness.Equal("{ this is not json", File.ReadAllText(path));
        });

        TestHarness.Run("settings empty file throws", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "windows-settings.json");
            File.WriteAllText(path, "");
            TestHarness.Throws<SettingsException>(() => SettingsStore.LoadFrom(path), "not valid JSON");
        });

        TestHarness.Run("settings save is atomic and leaves no temp files", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "windows-settings.json");
            SettingsStore.SaveTo(path, new AppSettings(ClaudeConfigDirectory: "/one"));
            SettingsStore.SaveTo(path, new AppSettings(ClaudeConfigDirectory: "/two"));
            var files = Directory.GetFiles(temp.Path);
            TestHarness.Equal(1, files.Length, "file count");
            TestHarness.Equal("/two", SettingsStore.LoadFrom(path).ClaudeConfigDirectory);
        });

        TestHarness.Run("settings ignore unknown properties", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, "windows-settings.json");
            File.WriteAllText(path, "{\"claudeConfigDirectory\":\"/claude\",\"futureOption\":true}");
            TestHarness.Equal("/claude", SettingsStore.LoadFrom(path).ClaudeConfigDirectory);
        });
    }
}
