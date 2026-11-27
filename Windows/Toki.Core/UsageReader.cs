namespace Toki.Core;

public static class UsageReader {
    public static Task<IReadOnlyList<ProviderSnapshot>> RefreshAsync(AppSettings settings, CancellationToken cancellationToken) {
        var claude = Claude.ClaudeUsageProvider.CreateDefault();
        var codex = Codex.CodexUsageProvider.CreateDefault();
        return RefreshAsync(settings, cancellationToken, claude.FetchAsync, codex.FetchSnapshotAsync);
    }

    internal static async Task<IReadOnlyList<ProviderSnapshot>> RefreshAsync(
        AppSettings settings,
        CancellationToken cancellationToken,
        Func<AppSettings, CancellationToken, Task<ProviderSnapshot>> claude,
        Func<AppSettings, CancellationToken, Task<ProviderSnapshot>> codex) {
        var checkedAt = DateTimeOffset.UtcNow;
        var claudeTask = SafeAsync("claude-code", "Claude Code", claude, settings, cancellationToken, checkedAt);
        var codexTask = SafeAsync("codex", "Codex", codex, settings, cancellationToken, checkedAt);
        return await Task.WhenAll(claudeTask, codexTask);
    }

    private static async Task<ProviderSnapshot> SafeAsync(
        string id,
        string name,
        Func<AppSettings, CancellationToken, Task<ProviderSnapshot>> read,
        AppSettings settings,
        CancellationToken cancellationToken,
        DateTimeOffset checkedAt) {
        try {
            return await read(settings, cancellationToken);
        } catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) {
            throw;
        } catch (Exception ex) {
            var message = ex is ProviderException
                ? ex.Message
                : "Unexpected error reading " + name + " usage.";
            return new ProviderSnapshot(id, name, "Unavailable", Array.Empty<QuotaWindow>(), message, checkedAt);
        }
    }
}
