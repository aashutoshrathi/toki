using System.Text.Json;

namespace Toki.Core.Tests;

internal static class FakeAppServer {
    internal static async Task RunAsync() {
        var mode = Environment.GetEnvironmentVariable("TOKI_FAKE_MODE") ?? "normal";
        var pidFile = Environment.GetEnvironmentVariable("TOKI_FAKE_PID_FILE");
        if (!string.IsNullOrEmpty(pidFile)) {
            File.WriteAllText(pidFile, Environment.ProcessId.ToString());
        }
        if (mode == "silent" || mode == "hang") {
            await Task.Delay(TimeSpan.FromSeconds(mode == "hang" ? 60 : 30));
            return;
        }
        if (mode == "unterminated") {
            Console.Write(new string('x', 300 * 1024));
            Console.Out.Flush();
            await Task.Delay(TimeSpan.FromSeconds(30));
            return;
        }
        if (mode == "flood") {
            var huge = new string('x', 300 * 1024);
            Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"blob\":\"" + huge + "\"}}");
            await Task.Delay(TimeSpan.FromSeconds(30));
            return;
        }
        string? line;
        while ((line = await Console.In.ReadLineAsync()) is not null) {
            if (string.IsNullOrWhiteSpace(line)) {
                continue;
            }
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("id", out var idElement) || !idElement.TryGetInt32(out var id)) {
                if (root.TryGetProperty("method", out var notification) && notification.GetString() == "initialized") {
                    Console.WriteLine("{\"jsonrpc\":\"2.0\",\"method\":\"account/updated\",\"params\":{}}");
                }
                continue;
            }
            var method = root.TryGetProperty("method", out var methodElement) ? methodElement.GetString() : null;
            switch (method) {
                case "initialize":
                    Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":{\"userAgent\":\"fake\"}}");
                    break;
                case "account/rateLimits/read":
                    if (mode == "error") {
                        Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"error\":{\"code\":-32600,\"message\":\"codex account authentication required to read rate limits\"}}");
                    } else {
                        Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"planType\":\"pro\",\"primary\":{\"usedPercent\":25,\"resetsAt\":1893456000,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":80,\"resetsAt\":1893542400,\"windowDurationMins\":10080}}}}}");
                    }
                    break;
                case "account/read":
                    Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"tester@example.com\"}}}");
                    break;
                default:
                    Console.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"error\":{\"code\":-32601,\"message\":\"unknown method\"}}");
                    break;
            }
        }
    }
}
