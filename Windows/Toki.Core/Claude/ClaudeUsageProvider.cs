using System.Net;
using System.Text;

namespace Toki.Core.Claude;

internal sealed class ClaudeUsageProvider {
    internal static readonly Uri UsageUri = new("https://api.anthropic.com/api/oauth/usage?cedar_ember=1");
    internal const string BetaHeader = "oauth-2025-04-20";
    internal const string UserAgent = "claude-cli/2.1.280 (external, cli)";
    internal static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(10);
    internal const int MaximumResponseBytes = 512 * 1024;

    private static readonly HttpClient SharedHttpClient = new() { Timeout = Timeout.InfiniteTimeSpan };

    private readonly HttpClient _http;
    private readonly Func<AppSettings, ClaudeCredential> _credentialLoader;
    private readonly Func<DateTimeOffset> _clock;
    private readonly TimeSpan _requestTimeout;
    private readonly Uri _usageUri;

    internal ClaudeUsageProvider(
        HttpClient http,
        Func<AppSettings, ClaudeCredential> credentialLoader,
        Func<DateTimeOffset> clock,
        TimeSpan? requestTimeout = null,
        Uri? usageUri = null) {
        _http = http;
        _credentialLoader = credentialLoader;
        _clock = clock;
        _requestTimeout = requestTimeout ?? DefaultRequestTimeout;
        _usageUri = usageUri ?? UsageUri;
    }

    internal static ClaudeUsageProvider CreateDefault() {
        return new ClaudeUsageProvider(
            SharedHttpClient,
            settings => ClaudeCredentialReader.Load(
                settings,
                EnvironmentSnapshot.Read(),
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                DateTimeOffset.UtcNow),
            () => DateTimeOffset.UtcNow);
    }

    internal async Task<ProviderSnapshot> FetchAsync(AppSettings settings, CancellationToken cancellationToken) {
        var now = _clock();
        var credential = _credentialLoader(settings);
        using var request = new HttpRequestMessage(HttpMethod.Get, _usageUri);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + credential.AccessToken);
        request.Headers.TryAddWithoutValidation("anthropic-beta", BetaHeader);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_requestTimeout);

        HttpResponseMessage response;
        try {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        } catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) {
            throw new ProviderException("Claude Code usage request timed out. Check your network and refresh.");
        } catch (HttpRequestException) {
            throw new ProviderException("Couldn't reach Anthropic to read Claude Code usage. Check your network and refresh.");
        }

        using (response) {
            if (response.StatusCode == HttpStatusCode.Unauthorized) {
                throw new ProviderException(
                    "Anthropic rejected this Claude Code sign-in. Open Claude Code or try /status in an existing session, then refresh Toki. Use /login only if Claude Code cannot restore access.");
            }
            if (!response.IsSuccessStatusCode) {
                throw new ProviderException($"Anthropic returned HTTP {(int)response.StatusCode} for Claude Code usage.");
            }
            string body;
            try {
                body = await ReadBoundedAsync(response, timeout.Token);
            } catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) {
                throw new ProviderException("Claude Code usage request timed out. Check your network and refresh.");
            } catch (IOException) {
                throw new ProviderException("Claude Code usage response could not be read. Check your network and refresh.");
            }
            var usage = ClaudeUsageParser.Parse(body);
            return new ProviderSnapshot(
                "claude-code",
                "Claude Code",
                credential.Email ?? "Claude Code OAuth usage",
                usage.Windows,
                null,
                now);
        }
    }

    private static async Task<string> ReadBoundedAsync(HttpResponseMessage response, CancellationToken cancellationToken) {
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        while (true) {
            var read = await stream.ReadAsync(chunk, cancellationToken);
            if (read == 0) {
                break;
            }
            if (buffer.Length + read > MaximumResponseBytes) {
                throw new ProviderException("Claude Code usage response was too large to read.");
            }
            buffer.Write(chunk, 0, read);
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }
}
