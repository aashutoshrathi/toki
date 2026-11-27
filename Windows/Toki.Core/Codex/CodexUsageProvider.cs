using System.Text.Json;

namespace Toki.Core.Codex;

internal sealed class CodexUsageProvider {
    internal static readonly TimeSpan DefaultTotalTimeout = TimeSpan.FromSeconds(20);
    internal static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(10);

    private readonly Func<AppSettings, CodexLaunch> _resolver;
    private readonly Func<AppSettings, string> _homeResolver;
    private readonly Func<CodexLaunch, string, CancellationToken, Task<CodexAppServerPayload>> _fetch;
    private readonly Func<DateTimeOffset> _clock;
    private readonly TimeSpan _totalTimeout;

    internal CodexUsageProvider(
        Func<AppSettings, CodexLaunch> resolver,
        Func<AppSettings, string> homeResolver,
        Func<CodexLaunch, string, CancellationToken, Task<CodexAppServerPayload>> fetch,
        Func<DateTimeOffset> clock,
        TimeSpan? totalTimeout = null) {
        _resolver = resolver;
        _homeResolver = homeResolver;
        _fetch = fetch;
        _clock = clock;
        _totalTimeout = totalTimeout ?? DefaultTotalTimeout;
    }

    internal static CodexUsageProvider CreateDefault() {
        var environment = EnvironmentSnapshot.Read();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new CodexUsageProvider(
            settings => CodexBinaryResolver.Resolve(settings, environment, home),
            settings => CodexBinaryResolver.CodexHome(settings, environment, home),
            FetchAsync,
            () => DateTimeOffset.UtcNow);
    }

    internal async Task<ProviderSnapshot> FetchSnapshotAsync(AppSettings settings, CancellationToken cancellationToken) {
        var now = _clock();
        var launch = _resolver(settings);
        var home = _homeResolver(settings);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_totalTimeout);
        CodexAppServerPayload payload;
        try {
            payload = await _fetch(launch, home, timeout.Token);
        } catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) {
            throw new ProviderException("Codex app-server timed out. Open Codex once, then refresh Toki.");
        }
        var parsed = CodexUsageParser.Parse(payload.RateLimits, payload.Account);
        return new ProviderSnapshot("codex", "Codex", parsed.Detail, parsed.Windows, null, now);
    }

    internal static async Task<CodexAppServerPayload> FetchAsync(
        CodexLaunch launch,
        string codexHome,
        CancellationToken cancellationToken) {
        using var transport = new CodexAppServerTransport(launch, codexHome, DefaultRequestTimeout);
        using var cancellationRegistration = cancellationToken.Register(transport.Cancel);
        await transport.InitializeAsync(cancellationToken);
        var rateLimits = await transport.RequestAsync(2, "account/rateLimits/read", null, cancellationToken);
        if (rateLimits.Error is { } error) {
            throw new ProviderException(DescribeRateLimitError(error));
        }
        if (rateLimits.Result is null) {
            throw new ProviderException("Codex app-server did not return rate limits.");
        }
        var account = await transport.RequestAsync(3, "account/read", "{\"refreshToken\":false}", cancellationToken);
        return new CodexAppServerPayload(rateLimits.Result, account.Error is null ? account.Result : null);
    }

    internal static string DescribeRateLimitError(JsonElement error) {
        var message = JsonHelpers.TryGetString(error, "message") ?? "Codex rate limits unavailable";
        var code = error.TryGetProperty("code", out var codeElement) && codeElement.ValueKind == JsonValueKind.Number && codeElement.TryGetInt32(out var parsed) ? parsed : (int?)null;
        if (code == -32600 && message.Contains("authentication required", StringComparison.OrdinalIgnoreCase)) {
            return "Codex is signed out. Open Codex to sign in.";
        }
        if (code == -32603
            && message.StartsWith("failed to fetch codex rate limits: GET ", StringComparison.Ordinal)
            && message.Contains("/backend-api/wham/usage failed: 401 Unauthorized", StringComparison.Ordinal)) {
            return "Codex sign-in expired. Open Codex to sign in again.";
        }
        return CodexAppServerTransport.DescribeError(error) + ". Open Codex to check its connection, then refresh Toki.";
    }
}
