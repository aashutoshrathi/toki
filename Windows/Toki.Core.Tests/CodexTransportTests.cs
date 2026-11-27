using System.Diagnostics;
using System.Text.Json;
using Toki.Core.Codex;

namespace Toki.Core.Tests;

internal static class CodexTransportTests {
    internal static async Task RunAsync() {
        await TestHarness.RunAsync("codex transport completes handshake and reads rate limits", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("normal", out _);
            using var transport = new CodexAppServerTransport(launch, temp.Path, TimeSpan.FromSeconds(5));
            await transport.InitializeAsync(CancellationToken.None);
            var rateLimits = await transport.RequestAsync(2, "account/rateLimits/read", null, CancellationToken.None);
            TestHarness.True(rateLimits.Error is null, "rate limits should not error");
            TestHarness.True(rateLimits.Result is not null, "rate limits should return a result");
            var account = await transport.RequestAsync(3, "account/read", "{\"refreshToken\":false}", CancellationToken.None);
            TestHarness.True(account.Result is not null, "account should return a result");
        });

        await TestHarness.RunAsync("codex provider builds a snapshot from app-server", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("normal", out _);
            var provider = new CodexUsageProvider(
                _ => launch,
                _ => temp.Path,
                CodexUsageProvider.FetchAsync,
                () => DateTimeOffset.UtcNow);
            var snapshot = await provider.FetchSnapshotAsync(new AppSettings(), CancellationToken.None);
            TestHarness.Equal("codex", snapshot.Id);
            TestHarness.Equal("OpenAI Codex - pro", snapshot.Detail);
            TestHarness.Equal(2, snapshot.Windows.Count);
            TestHarness.Equal(75.0, snapshot.Windows[0].RemainingPercent);
            TestHarness.Equal(20.0, snapshot.Windows[1].RemainingPercent);
            TestHarness.Equal<string?>(null, snapshot.Error);
        });

        await TestHarness.RunAsync("codex provider reports signed-out account", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("error", out _);
            await TestHarness.ThrowsAsync<ProviderException>(
                () => CodexUsageProvider.FetchAsync(launch, temp.Path, CancellationToken.None),
                "signed out");
        });

        await TestHarness.RunAsync("codex transport times out", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("silent", out _);
            using var transport = new CodexAppServerTransport(launch, temp.Path, TimeSpan.FromSeconds(1));
            await TestHarness.ThrowsAsync<ProviderException>(
                () => transport.InitializeAsync(CancellationToken.None),
                "timed out");
        });

        await TestHarness.RunAsync("codex transport bounds oversized output", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("flood", out _);
            using var transport = new CodexAppServerTransport(launch, temp.Path, TimeSpan.FromSeconds(5));
            await TestHarness.ThrowsAsync<ProviderException>(
                () => transport.InitializeAsync(CancellationToken.None),
                "more output");
        });

        await TestHarness.RunAsync("codex transport rejects oversized unterminated lines before timeout", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("unterminated", out _);
            using var transport = new CodexAppServerTransport(launch, temp.Path, TimeSpan.FromSeconds(5));
            await TestHarness.ThrowsAsync<ProviderException>(
                () => transport.InitializeAsync(CancellationToken.None), "more output");
        });

        TestHarness.Run("codex errors do not expose server response text", () => {
            using var error = JsonDocument.Parse("""{"code":-32000,"message":"failure Bearer secret-token"}""");
            TestHarness.True(!CodexAppServerTransport.DescribeError(error.RootElement).Contains("secret-token"), "initialization error leaks token");
            TestHarness.True(!CodexUsageProvider.DescribeRateLimitError(error.RootElement).Contains("secret-token"), "rate limit error leaks token");
        });

        TestHarness.Run("codex auth remedy requires the known backend 401 shape", () => {
            using var genuine = JsonDocument.Parse("""{"code":-32603,"message":"failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"}""");
            using var unrelated = JsonDocument.Parse("""{"code":-32603,"message":"backend returned 4010"}""");
            using var wrongCode = JsonDocument.Parse("""{"code":-32000,"message":"failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"}""");
            TestHarness.True(CodexUsageProvider.DescribeRateLimitError(genuine.RootElement).Contains("sign-in expired"), "known 401 should explain sign-in expiry");
            TestHarness.True(!CodexUsageProvider.DescribeRateLimitError(unrelated.RootElement).Contains("sign-in expired"), "4010 is not HTTP 401");
            TestHarness.True(!CodexUsageProvider.DescribeRateLimitError(wrongCode.RootElement).Contains("sign-in expired"), "unrelated RPC errors should stay generic");
        });

        await TestHarness.RunAsync("codex provider cancellation kills its child process", async () => {
            using var temp = new TempDirectory();
            using var cancellation = new CancellationTokenSource();
            var launch = FakeLaunch("hang", out var pidFile);
            var fetch = CodexUsageProvider.FetchAsync(launch, temp.Path, cancellation.Token);
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (!File.Exists(pidFile) && DateTime.UtcNow < deadline) {
                await Task.Delay(20);
            }
            cancellation.Cancel();
            await TestHarness.ThrowsAsync<OperationCanceledException>(() => fetch, "");
            var pid = int.Parse(File.ReadAllText(pidFile).Trim());
            TestHarness.True(await WaitForExitAsync(pid, TimeSpan.FromSeconds(5)), "cancelled app-server should exit");
            File.Delete(pidFile);
        });

        await TestHarness.RunAsync("codex transport cleans up the child process", async () => {
            using var temp = new TempDirectory();
            var launch = FakeLaunch("hang", out var pidFile);
            var transport = new CodexAppServerTransport(launch, temp.Path, TimeSpan.FromSeconds(1));
            await TestHarness.ThrowsAsync<ProviderException>(
                () => transport.InitializeAsync(CancellationToken.None),
                "timed out");
            transport.Dispose();
            var pid = int.Parse(File.ReadAllText(pidFile).Trim());
            var gone = await WaitForExitAsync(pid, TimeSpan.FromSeconds(5));
            TestHarness.True(gone, "fake app-server process should be gone");
        });
    }

    private static CodexLaunch FakeLaunch(string mode, out string pidFile) {
        pidFile = Path.Combine(Path.GetTempPath(), "toki-fake-" + Guid.NewGuid().ToString("N") + ".pid");
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("process path is unavailable");
        var arguments = new List<string>();
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) {
            arguments.Add(typeof(FakeAppServer).Assembly.Location);
        }
        var environment = new Dictionary<string, string> {
            ["TOKI_FAKE_APP_SERVER"] = "1",
            ["TOKI_FAKE_MODE"] = mode,
            ["TOKI_FAKE_PID_FILE"] = pidFile
        };
        return new CodexLaunch(executable, arguments, "fake", environment);
    }

    private static async Task<bool> WaitForExitAsync(int pid, TimeSpan timeout) {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline) {
            if (!IsRunning(pid)) {
                return true;
            }
            await Task.Delay(50);
        }
        return !IsRunning(pid);
    }

    private static bool IsRunning(int pid) {
        try {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        } catch (ArgumentException) {
            return false;
        }
    }
}
