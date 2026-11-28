using System.Diagnostics;
using System.Text.Json;
using Toki.Core;

namespace Toki.Windows;

internal sealed class RemoteCompanion : IDisposable {
    private Process? _process;
    internal event Action<string>? Output;
    internal event Action? Stopped;
    internal bool Running => _process is { HasExited: false };
    internal string? Token { get; private set; }
    internal string? PairingCode { get; private set; }
    internal string Devices { get; private set; } = "[]";

    internal void Start(string access) {
        if (Running) {
            return;
        }
        Stop();
        if (access is not ("loopback" or "private" or "tailnet")) {
            throw new ArgumentException("Unsupported reach.");
        }
        var root = AppContext.BaseDirectory;
        var python = Path.Combine(root, "python", "python.exe");
        var script = Path.Combine(root, "remote", "toki_windows_remote.py");
        if (!File.Exists(python) || !File.Exists(script)) {
            throw new InvalidOperationException("Remote Control requires the packaged Windows build with its bundled Python runtime.");
        }
        var start = new ProcessStartInfo(python) {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new System.Text.UTF8Encoding(false),
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
        foreach (var arg in new[] { "-u", script, "--bind", access == "loopback" ? "127.0.0.1" : "0.0.0.0", "--port", "8765", "--access", access, "--agent-snapshot-stdin", "--no-qr" }) {
            start.ArgumentList.Add(arg);
        }
        var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        _process = process;
        process.OutputDataReceived += (_, e) => {
            if (e.Data is { } line && ReferenceEquals(_process, process)) {
                if (line.StartsWith("pairing_code=")) {
                    PairingCode = line[13..];
                } else if (line.StartsWith("devices=")) {
                    Devices = line[8..];
                } else if (line.Trim().StartsWith("http://localhost:8765/?token=")) {
                    Token = line.Trim().Split("token=", 2)[1];
                }
                Output?.Invoke("updated");
            }
        };
        process.ErrorDataReceived += (_, _) => { };
        process.Exited += (_, _) => {
            if (ReferenceEquals(_process, process)) {
                Token = null;
                PairingCode = null;
                Stopped?.Invoke();
            }
        };
        try {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        } catch {
            _process = null;
            process.Dispose();
            throw;
        }
    }

    internal void Publish(IReadOnlyList<ProviderSnapshot> snapshots, IReadOnlyList<LocalSession> sessions, bool shareTranscripts) {
        Send(new { agents = shareTranscripts ? sessions.Select(s => new { pid = s.Id, provider = s.Provider, title = s.Title, session = s.Path, process = false }).ToArray() : [] });
        var now = DateTimeOffset.UtcNow;
        Send(new { usage = snapshots.Select(s => {
            var valid = s.Error is null && now - s.CheckedAt <= TimeSpan.FromMinutes(2);
            return new {
                id = s.Id, name = s.Name, provider = s.Id == "claude-code" ? "claudeCode" : "codex",
                primary = valid ? "Remaining quota" : "Unavailable or stale", error = !valid,
                remaining = valid && s.Windows.Count > 0 ? s.Windows.Min(w => w.RemainingPercent) / 100 : (double?)null,
                windows = valid ? s.Windows.Select(w => new { label = w.Label, left = w.RemainingPercent, reset = w.ResetsAt?.ToLocalTime().ToString("g") }).ToArray() : []
            };
        }).ToArray() });
    }

    internal void Revoke(string id) => Send(new { revoke = id });

    private void Send(object message) {
        if (!Running) {
            return;
        }
        try {
            _process!.StandardInput.WriteLine(JsonSerializer.Serialize(message));
            _process.StandardInput.Flush();
        } catch (Exception ex) when (ex is IOException or InvalidOperationException) {
            Stop();
            Stopped?.Invoke();
        }
    }

    internal void Stop() {
        var process = _process;
        _process = null;
        Token = null;
        PairingCode = null;
        Devices = "[]";
        if (process is not null) {
            try {
                if (!process.HasExited) {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(3000);
                }
            } catch (InvalidOperationException) {
            } finally {
                process.Dispose();
            }
        }
    }

    public void Dispose() => Stop();
}
