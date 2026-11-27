using System.Net;
using System.Net.Sockets;
using System.Text;
using Toki.Core.Claude;

namespace Toki.Core.Tests;

internal sealed class StubHandler : HttpMessageHandler {
    private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _responder;

    internal string? Authorization { get; private set; }
    internal string? Beta { get; private set; }
    internal string? UserAgent { get; private set; }

    internal StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) {
        _responder = (request, _) => Task.FromResult(responder(request));
    }

    internal StubHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> responder) {
        _responder = responder;
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        Authorization = request.Headers.TryGetValues("Authorization", out var authorization) ? authorization.FirstOrDefault() : null;
        Beta = request.Headers.TryGetValues("anthropic-beta", out var beta) ? beta.FirstOrDefault() : null;
        UserAgent = request.Headers.NonValidated.TryGetValues("User-Agent", out var userAgent)
            ? string.Join(", ", userAgent)
            : null;
        return _responder(request, cancellationToken);
    }
}

internal static class ClaudeProviderTests {
    private static readonly DateTimeOffset Now = new(2026, 11, 27, 12, 0, 0, TimeSpan.Zero);

    internal static async Task RunAsync() {
        await TestHarness.RunAsync("claude provider sends oauth headers and parses usage", async () => {
            var handler = new StubHandler(_ => Json("{\"five_hour\":{\"utilization\":0},\"seven_day\":{\"utilization\":100}}"));
            var provider = new ClaudeUsageProvider(
                new HttpClient(handler),
                _ => new ClaudeCredential("secret-token", null, "test", "user@example.com"),
                () => Now);
            var snapshot = await provider.FetchAsync(new AppSettings(), CancellationToken.None);
            TestHarness.Equal("claude-code", snapshot.Id);
            TestHarness.Equal("user@example.com", snapshot.Detail);
            TestHarness.Equal(2, snapshot.Windows.Count);
            TestHarness.Equal("Bearer secret-token", handler.Authorization);
            TestHarness.Equal(ClaudeUsageProvider.BetaHeader, handler.Beta);
            TestHarness.Equal(ClaudeUsageProvider.UserAgent, handler.UserAgent);
            TestHarness.Equal<string?>(null, snapshot.Error);
        });

        await TestHarness.RunAsync("claude provider sends exact headers on the wire", async () => {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var server = Task.Run(async () => {
                using var client = await listener.AcceptTcpClientAsync();
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII);
                var headers = new List<string>();
                string? line;
                while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync())) {
                    headers.Add(line);
                }
                var body = "{\"five_hour\":{\"utilization\":0}}";
                var response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                    + Encoding.UTF8.GetByteCount(body)
                    + "\r\nConnection: close\r\n\r\n"
                    + body;
                await stream.WriteAsync(Encoding.UTF8.GetBytes(response));
                return headers;
            });
            try {
                var provider = new ClaudeUsageProvider(
                    new HttpClient(new HttpClientHandler { UseProxy = false }),
                    _ => new ClaudeCredential("secret-token", null, "test", null),
                    () => Now,
                    TimeSpan.FromSeconds(5),
                    new Uri($"http://127.0.0.1:{port}/usage"));
                var snapshot = await provider.FetchAsync(new AppSettings(), CancellationToken.None);
                TestHarness.Equal(1, snapshot.Windows.Count);
                var headers = await server;
                TestHarness.True(
                    headers.Any(header => header.Equals("User-Agent: " + ClaudeUsageProvider.UserAgent, StringComparison.OrdinalIgnoreCase)),
                    "user agent should be sent exactly");
                TestHarness.True(
                    headers.Any(header => header.Equals("anthropic-beta: " + ClaudeUsageProvider.BetaHeader, StringComparison.OrdinalIgnoreCase)),
                    "beta header should be sent");
                TestHarness.True(
                    headers.Any(header => header.Equals("Authorization: Bearer secret-token", StringComparison.OrdinalIgnoreCase)),
                    "authorization should be sent");
            } finally {
                listener.Stop();
            }
        });

        await TestHarness.RunAsync("claude provider sanitizes unauthorized errors", async () => {
            var handler = new StubHandler(_ => Json("{\"error\":\"SECRET-BODY\"}", HttpStatusCode.Unauthorized));
            var provider = new ClaudeUsageProvider(
                new HttpClient(handler),
                _ => new ClaudeCredential("secret-token", null, "test", null),
                () => Now);
            try {
                await provider.FetchAsync(new AppSettings(), CancellationToken.None);
                throw new Exception("expected ProviderException");
            } catch (ProviderException ex) {
                TestHarness.True(ex.Message.Contains("rejected", StringComparison.OrdinalIgnoreCase), "should explain rejection");
                TestHarness.True(!ex.Message.Contains("SECRET-BODY", StringComparison.Ordinal), "must not leak response body");
                TestHarness.True(!ex.Message.Contains("secret-token", StringComparison.Ordinal), "must not leak token");
            }
        });

        await TestHarness.RunAsync("claude provider reports status without body", async () => {
            var handler = new StubHandler(_ => Json("{\"error\":\"SECRET-BODY\"}", HttpStatusCode.InternalServerError));
            var provider = new ClaudeUsageProvider(
                new HttpClient(handler),
                _ => new ClaudeCredential("secret-token", null, "test", null),
                () => Now);
            try {
                await provider.FetchAsync(new AppSettings(), CancellationToken.None);
                throw new Exception("expected ProviderException");
            } catch (ProviderException ex) {
                TestHarness.True(ex.Message.Contains("500", StringComparison.Ordinal), "should include status");
                TestHarness.True(!ex.Message.Contains("SECRET-BODY", StringComparison.Ordinal), "must not leak response body");
            }
        });

        await TestHarness.RunAsync("claude provider times out", async () => {
            var handler = new StubHandler(async (_, cancellationToken) => {
                await Task.Delay(Timeout.Infinite, cancellationToken);
                throw new InvalidOperationException("unreachable");
            });
            var provider = new ClaudeUsageProvider(
                new HttpClient(handler),
                _ => new ClaudeCredential("secret-token", null, "test", null),
                () => Now,
                TimeSpan.FromMilliseconds(100));
            await TestHarness.ThrowsAsync<ProviderException>(
                () => provider.FetchAsync(new AppSettings(), CancellationToken.None),
                "timed out");
        });

        await TestHarness.RunAsync("claude provider rejects oversized response", async () => {
            var body = "{\"five_hour\":{\"utilization\":1},\"pad\":\"" + new string('x', ClaudeUsageProvider.MaximumResponseBytes) + "\"}";
            var handler = new StubHandler(_ => Json(body));
            var provider = new ClaudeUsageProvider(
                new HttpClient(handler),
                _ => new ClaudeCredential("secret-token", null, "test", null),
                () => Now);
            await TestHarness.ThrowsAsync<ProviderException>(
                () => provider.FetchAsync(new AppSettings(), CancellationToken.None),
                "too large");
        });

        await TestHarness.RunAsync("claude provider surfaces malformed usage", async () => {
            var handler = new StubHandler(_ => Json("{\"five_hour\":{}}"));
            var provider = new ClaudeUsageProvider(
                new HttpClient(handler),
                _ => new ClaudeCredential("secret-token", null, "test", null),
                () => Now);
            await TestHarness.ThrowsAsync<ProviderException>(
                () => provider.FetchAsync(new AppSettings(), CancellationToken.None),
                "unavailable");
        });
    }

    private static HttpResponseMessage Json(string body, HttpStatusCode status = HttpStatusCode.OK) {
        return new HttpResponseMessage(status) {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
    }
}
