using Toki.Core.Claude;

namespace Toki.Core.Tests;

internal static class ClaudeCredentialTests {
    private static readonly DateTimeOffset Now = new(2026, 11, 27, 12, 0, 0, TimeSpan.Zero);

    internal static void Run() {
        TestHarness.Run("claude credentials parse token and email", () => {
            var credential = ClaudeCredentialReader.Parse(
                "{\"claudeAiOauth\":{\"accessToken\":\"token-123\",\"expiresAt\":1893456000000,\"email\":\"user@example.com\"}}",
                "test",
                Now);
            TestHarness.Equal("token-123", credential.AccessToken);
            TestHarness.Equal("user@example.com", credential.Email);
            TestHarness.True(credential.ExpiresAt is not null, "expiry should parse");
        });

        TestHarness.Run("claude credentials reject expired sign-in", () => {
            var expired = Now.AddMinutes(-5).ToUnixTimeMilliseconds();
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Parse(
                    "{\"claudeAiOauth\":{\"accessToken\":\"token-123\",\"expiresAt\":" + expired + "}}",
                    "test",
                    Now),
                "expired");
        });

        TestHarness.Run("claude credentials reject missing oauth section", () => {
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Parse("{\"apiKey\":\"secret\"}", "test", Now),
                "claudeAiOauth");
        });

        TestHarness.Run("claude credentials reject missing access token", () => {
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Parse("{\"claudeAiOauth\":{\"expiresAt\":1893456000000}}", "test", Now),
                "access token");
        });

        TestHarness.Run("claude credentials reject invalid json", () => {
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Parse("not json", "test", Now),
                "not valid JSON");
        });

        TestHarness.Run("claude credential file rejects missing file", () => {
            using var temp = new TempDirectory();
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Read(Path.Combine(temp.Path, ".credentials.json"), Now),
                "no such file");
        });

        TestHarness.Run("claude credential file rejects oversized file", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, ".credentials.json");
            File.WriteAllText(path, new string('x', (int)ClaudeCredentialReader.MaximumBytes + 1));
            TestHarness.Throws<ProviderException>(() => ClaudeCredentialReader.Read(path, Now), "far bigger");
        });

        TestHarness.Run("claude credential file rejects empty file", () => {
            using var temp = new TempDirectory();
            var path = Path.Combine(temp.Path, ".credentials.json");
            File.WriteAllText(path, "");
            TestHarness.Throws<ProviderException>(() => ClaudeCredentialReader.Read(path, Now), "empty");
        });

        TestHarness.Run("claude explicit directory does not fall back to default", () => {
            using var temp = new TempDirectory();
            var home = Path.Combine(temp.Path, "home");
            Directory.CreateDirectory(Path.Combine(home, ".claude"));
            File.WriteAllText(
                Path.Combine(home, ".claude", ".credentials.json"),
                "{\"claudeAiOauth\":{\"accessToken\":\"home-token\"}}");
            var explicitDirectory = Path.Combine(temp.Path, "empty");
            Directory.CreateDirectory(explicitDirectory);
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Load(
                    new AppSettings(ClaudeConfigDirectory: explicitDirectory),
                    new Dictionary<string, string?>(),
                    home,
                    Now),
                "no such file");
        });

        TestHarness.Run("claude default directory finds home sign-in", () => {
            using var temp = new TempDirectory();
            var home = Path.Combine(temp.Path, "home");
            Directory.CreateDirectory(Path.Combine(home, ".claude"));
            File.WriteAllText(
                Path.Combine(home, ".claude", ".credentials.json"),
                "{\"claudeAiOauth\":{\"accessToken\":\"home-token\"}}");
            var credential = ClaudeCredentialReader.Load(new AppSettings(), new Dictionary<string, string?>(), home, Now);
            TestHarness.Equal("home-token", credential.AccessToken);
        });

        TestHarness.Run("claude environment directory is used without fallback", () => {
            using var temp = new TempDirectory();
            var home = Path.Combine(temp.Path, "home");
            Directory.CreateDirectory(Path.Combine(home, ".claude"));
            File.WriteAllText(
                Path.Combine(home, ".claude", ".credentials.json"),
                "{\"claudeAiOauth\":{\"accessToken\":\"home-token\"}}");
            var custom = Path.Combine(temp.Path, "custom");
            Directory.CreateDirectory(custom);
            File.WriteAllText(
                Path.Combine(custom, ".credentials.json"),
                "{\"claudeAiOauth\":{\"accessToken\":\"custom-token\"}}");
            var environment = new Dictionary<string, string?> { ["CLAUDE_CONFIG_DIR"] = custom };
            var credential = ClaudeCredentialReader.Load(new AppSettings(), environment, home, Now);
            TestHarness.Equal("custom-token", credential.AccessToken);
        });

        TestHarness.Run("claude relative explicit directory is rejected", () => {
            using var temp = new TempDirectory();
            TestHarness.Throws<ProviderException>(
                () => ClaudeCredentialReader.Load(
                    new AppSettings(ClaudeConfigDirectory: "relative/path"),
                    new Dictionary<string, string?>(),
                    temp.Path,
                    Now),
                "absolute path");
        });
    }
}
