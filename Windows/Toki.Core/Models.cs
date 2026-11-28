namespace Toki.Core;

public sealed record AppSettings(
    string? ClaudeConfigDirectory = null,
    string? CodexHome = null,
    string? CodexExecutable = null,
    bool NotificationsEnabled = true,
    bool DoNotDisturb = false,
    bool HideSensitiveInfo = false);

public sealed record QuotaWindow(string Label, double UsedPercent, DateTimeOffset? ResetsAt) {
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

public sealed record ProviderSnapshot(
    string Id,
    string Name,
    string Detail,
    IReadOnlyList<QuotaWindow> Windows,
    string? Error,
    DateTimeOffset CheckedAt);
