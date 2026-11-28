namespace Toki.Core.Tests;

internal static class UsageReaderTests {
    internal static async Task RunAsync() {
        await TestHarness.RunAsync("usage reader isolates provider failures", async () => {
            var snapshots = await UsageReader.RefreshAsync(
                new AppSettings(),
                CancellationToken.None,
                (_, _) => throw new ProviderException("claude down"),
                (_, _) => Task.FromResult(new ProviderSnapshot(
                    "codex",
                    "Codex",
                    "ok",
                    new[] { new QuotaWindow("5h", 10, null) },
                    null,
                    DateTimeOffset.UtcNow)));
            TestHarness.Equal(2, snapshots.Count);
            TestHarness.Equal("claude down", snapshots[0].Error);
            TestHarness.Equal(0, snapshots[0].Windows.Count);
            TestHarness.Equal<string?>(null, snapshots[1].Error);
            TestHarness.Equal(1, snapshots[1].Windows.Count);
        });

        await TestHarness.RunAsync("usage reader reports both providers independently", async () => {
            var snapshots = await UsageReader.RefreshAsync(
                new AppSettings(),
                CancellationToken.None,
                (_, _) => throw new ProviderException("claude down"),
                (_, _) => throw new ProviderException("codex down"));
            TestHarness.Equal("claude down", snapshots[0].Error);
            TestHarness.Equal("codex down", snapshots[1].Error);
        });

        await TestHarness.RunAsync("usage reader hides unexpected exception details", async () => {
            var snapshots = await UsageReader.RefreshAsync(
                new AppSettings(),
                CancellationToken.None,
                (_, _) => throw new InvalidOperationException("secret detail"),
                (_, _) => Task.FromResult(new ProviderSnapshot(
                    "codex",
                    "Codex",
                    "ok",
                    Array.Empty<QuotaWindow>(),
                    null,
                    DateTimeOffset.UtcNow)));
            TestHarness.True(snapshots[0].Error is not null, "error should be set");
            TestHarness.True(!snapshots[0].Error!.Contains("secret detail", StringComparison.Ordinal), "must not leak exception detail");
        });

        await TestHarness.RunAsync("usage reader propagates cancellation", async () => {
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();
            await TestHarness.ThrowsAsync<OperationCanceledException>(
                () => UsageReader.RefreshAsync(
                    new AppSettings(),
                    cancellation.Token,
                    (_, token) => Task.FromCanceled<ProviderSnapshot>(token),
                    (_, token) => Task.FromCanceled<ProviderSnapshot>(token)),
                "canceled");
        });
    }
}
