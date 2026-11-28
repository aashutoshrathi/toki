using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Toki.Core.Codex;

internal sealed record CodexRpcResponse(JsonElement? Result, JsonElement? Error);

internal sealed class CodexAppServerTransport : IDisposable {
    internal const int MaximumOutputBytes = 1024 * 1024;
    internal const int MaximumLineChars = 256 * 1024;
    internal static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(10);

    private readonly Process _process;
    private readonly StreamWriter _input;
    private readonly Channel<string> _lines = Channel.CreateUnbounded<string>(new UnboundedChannelOptions {
        SingleReader = true,
        SingleWriter = true
    });
    private readonly Task _stdoutTask;
    private readonly Task _stderrTask;
    private readonly SemaphoreSlim _requestLock = new(1, 1);
    private readonly TimeSpan _requestTimeout;
    private long _outputBytes;
    private volatile bool _overflow;
    private bool _closed;

    internal CodexAppServerTransport(CodexLaunch launch, string codexHome, TimeSpan? requestTimeout = null) {
        _requestTimeout = requestTimeout ?? DefaultRequestTimeout;
        var startInfo = new ProcessStartInfo {
            FileName = launch.ExecutablePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        foreach (var argument in launch.Arguments) {
            startInfo.ArgumentList.Add(argument);
        }
        startInfo.ArgumentList.Add("app-server");
        startInfo.ArgumentList.Add("--stdio");
        startInfo.Environment["CODEX_HOME"] = codexHome;
        if (launch.Environment is not null) {
            foreach (var pair in launch.Environment) {
                startInfo.Environment[pair.Key] = pair.Value;
            }
        }

        _process = new Process { StartInfo = startInfo };
        try {
            if (!_process.Start()) {
                throw new ProviderException("Codex app-server could not be started.");
            }
        } catch (ProviderException) {
            throw;
        } catch (Exception ex) when (ex is Win32Exception or InvalidOperationException) {
            throw new ProviderException("Codex app-server could not be started. Check the Codex executable in Toki settings.");
        }

        _input = _process.StandardInput;
        _input.AutoFlush = false;
        _stdoutTask = Task.Run(() => ReadStdoutAsync(_process.StandardOutput.BaseStream));
        _stderrTask = Task.Run(() => DrainAsync(_process.StandardError.BaseStream));
    }

    internal async Task InitializeAsync(CancellationToken cancellationToken) {
        var response = await RequestAsync(
            1,
            "initialize",
            "{\"clientInfo\":{\"name\":\"Toki\",\"version\":\"4.0.0-preview.2\"},\"capabilities\":{\"experimentalApi\":true}}",
            cancellationToken);
        if (response.Error is { } error) {
            throw new ProviderException("Codex app-server initialization failed: " + DescribeError(error));
        }
        await WriteLineAsync("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":null}", cancellationToken);
    }

    internal async Task<CodexRpcResponse> RequestAsync(
        int id,
        string method,
        string? paramsJson,
        CancellationToken cancellationToken) {
        await _requestLock.WaitAsync(cancellationToken);
        try {
            ThrowIfUnavailable();
            var line = paramsJson is null
                ? $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":{JsonSerializer.Serialize(method)},\"params\":null}}"
                : $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":{JsonSerializer.Serialize(method)},\"params\":{paramsJson}}}";
            await WriteLineAsync(line, cancellationToken);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_requestTimeout);
            while (true) {
                string incoming;
                try {
                    incoming = await _lines.Reader.ReadAsync(timeout.Token);
                } catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) {
                    KillProcess();
                    throw new ProviderException("Codex app-server timed out before replying.");
                } catch (ChannelClosedException) {
                    cancellationToken.ThrowIfCancellationRequested();
                    throw new ProviderException(_overflow
                        ? "Codex app-server sent more output than Toki reads."
                        : "Codex app-server stopped before replying.");
                }
                if (!TryParseLine(incoming, out var document)) {
                    continue;
                }
                using (document) {
                    var root = document.RootElement;
                    if (root.ValueKind != JsonValueKind.Object || root.TryGetProperty("method", out _)
                        || !root.TryGetProperty("id", out var idElement) || idElement.ValueKind != JsonValueKind.Number
                        || !idElement.TryGetInt32(out var responseId) || responseId != id) {
                        continue;
                    }
                    if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object) {
                        return new CodexRpcResponse(null, error.Clone());
                    }
                    if (root.TryGetProperty("result", out var result) && result.ValueKind != JsonValueKind.Null) {
                        return new CodexRpcResponse(result.Clone(), null);
                    }
                    return new CodexRpcResponse(null, null);
                }
            }
        } finally {
            _requestLock.Release();
        }
    }

    internal void Cancel() => KillProcess();

    public void Dispose() {
        if (_closed) {
            return;
        }
        _closed = true;
        try {
            _input.Dispose();
        } catch (IOException) {
        }
        KillProcess();
        try {
            _process.WaitForExit(2000);
        } catch (InvalidOperationException) {
        }
        try {
            if (!_process.HasExited) {
                _process.Kill(entireProcessTree: true);
            }
        } catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) {
        }
        try {
            _process.Dispose();
        } catch (InvalidOperationException) {
        }
        _requestLock.Dispose();
    }

    internal static string DescribeError(JsonElement error) {
        var code = error.TryGetProperty("code", out var codeElement)
            && codeElement.ValueKind == JsonValueKind.Number && codeElement.TryGetInt32(out var parsed) ? parsed : (int?)null;
        return code is null ? "Codex app-server request failed" : $"Codex app-server request failed (RPC {code})";
    }

    private async Task WriteLineAsync(string line, CancellationToken cancellationToken) {
        try {
            await _input.WriteLineAsync(line);
            await _input.FlushAsync(cancellationToken);
        } catch (Exception ex) when (ex is IOException or ObjectDisposedException) {
            throw new ProviderException("Codex app-server stopped before replying.");
        }
    }

    private void ThrowIfUnavailable() {
        if (_closed) {
            throw new ProviderException("Codex app-server is closed.");
        }
        if (_process.HasExited) {
            throw new ProviderException(_overflow
                ? "Codex app-server sent more output than Toki reads."
                : "Codex app-server stopped before replying.");
        }
    }

    private async Task ReadStdoutAsync(Stream stream) {
        using var reader = new StreamReader(stream, new UTF8Encoding(false));
        var buffer = new char[4096];
        var line = new StringBuilder();
        try {
            int count;
            while ((count = await reader.ReadAsync(buffer.AsMemory())) > 0) {
                _outputBytes += Encoding.UTF8.GetByteCount(buffer, 0, count);
                if (_outputBytes > MaximumOutputBytes) {
                    _overflow = true;
                    KillProcess();
                    break;
                }
                for (var i = 0; i < count; i++) {
                    if (buffer[i] == '\n') {
                        await _lines.Writer.WriteAsync(line.ToString());
                        line.Clear();
                    } else {
                        if (line.Length >= MaximumLineChars) {
                            _overflow = true;
                            KillProcess();
                            return;
                        }
                        line.Append(buffer[i]);
                    }
                }
            }
        } catch (Exception ex) when (ex is IOException or ObjectDisposedException) {
        } finally {
            _lines.Writer.TryComplete();
        }
    }

    private static async Task DrainAsync(Stream stream) {
        using var reader = new StreamReader(stream, new UTF8Encoding(false));
        var buffer = new char[4096];
        try {
            while (await reader.ReadAsync(buffer, 0, buffer.Length) > 0) {
            }
        } catch (Exception ex) when (ex is IOException or ObjectDisposedException) {
        }
    }

    private static bool TryParseLine(string line, out JsonDocument document) {
        document = null!;
        if (string.IsNullOrWhiteSpace(line)) {
            return false;
        }
        try {
            document = JsonDocument.Parse(line);
            return true;
        } catch (JsonException) {
            return false;
        }
    }

    private void KillProcess() {
        try {
            if (!_process.HasExited) {
                _process.Kill(entireProcessTree: true);
            }
        } catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException) {
        }
    }
}
