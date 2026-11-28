using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Toki.Core;

public sealed record LocalSession(long Id, string Provider, string Title, string Path, string? Directory, DateTimeOffset Modified);
public sealed record SessionScan(IReadOnlyList<LocalSession> Sessions, bool Incomplete);

public static class SessionCatalog {
    public const long MaximumFileSize = 16 * 1024 * 1024;

    public static SessionScan Scan(AppSettings settings, CancellationToken cancellationToken) {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var claude = settings.ClaudeConfigDirectory ?? Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") ?? System.IO.Path.Combine(home, ".claude");
        var codex = settings.CodexHome ?? Environment.GetEnvironmentVariable("CODEX_HOME") ?? System.IO.Path.Combine(home, ".codex");
        return ScanRoots(PathHelpers.ExpandPath(claude, home), PathHelpers.ExpandPath(codex, home), cancellationToken);
    }

    public static SessionScan ScanRoots(string claudeRoot, string codexRoot, CancellationToken cancellationToken) {
        var candidates = new List<(string Provider, FileInfo File)>();
        var incomplete = false;
        var visited = 0;
        foreach (var (provider, root) in new[] { ("claude", System.IO.Path.Combine(claudeRoot, "projects")), ("codex", System.IO.Path.Combine(codexRoot, "sessions")) }) {
            if (!System.IO.Path.IsPathFullyQualified(root)) {
                incomplete = true;
                continue;
            }
            var pending = new Stack<string>();
            pending.Push(root);
            while (pending.TryPop(out var directory)) {
                cancellationToken.ThrowIfCancellationRequested();
                if (++visited > 6000) {
                    incomplete = true;
                    break;
                }
                try {
                    if (!System.IO.Directory.Exists(directory)) {
                        continue;
                    }
                    if (!IsSafePath(directory)) {
                        incomplete = true;
                        continue;
                    }
                    foreach (var path in System.IO.Directory.EnumerateFileSystemEntries(directory)) {
                        cancellationToken.ThrowIfCancellationRequested();
                        if (++visited > 6000) {
                            incomplete = true;
                            break;
                        }
                        var attributes = File.GetAttributes(path);
                        if ((attributes & FileAttributes.ReparsePoint) != 0) {
                            incomplete = true;
                            continue;
                        }
                        if ((attributes & FileAttributes.Directory) != 0) {
                            pending.Push(path);
                        } else if (path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)) {
                            var file = new FileInfo(path);
                            if (file.Length > 0 && file.Length <= MaximumFileSize) {
                                candidates.Add((provider, file));
                            } else {
                                incomplete = true;
                            }
                        }
                    }
                } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) {
                    incomplete = true;
                }
            }
        }
        var sessions = new List<LocalSession>();
        foreach (var (provider, file) in candidates.OrderByDescending(c => c.File.LastWriteTimeUtc).Take(32)) {
            cancellationToken.ThrowIfCancellationRequested();
            try {
                if (!IsSafePath(file.FullName)) {
                    incomplete = true;
                    continue;
                }
                using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                var bytes = new byte[(int)Math.Min(stream.Length, 64 * 1024)];
                var count = stream.ReadAtLeast(bytes, bytes.Length, throwOnEndOfStream: false);
                string? cwd = null;
                string? title = null;
                foreach (var line in Encoding.UTF8.GetString(bytes, 0, count).Split('\n')) {
                    try {
                        using var json = JsonDocument.Parse(line);
                        var entry = json.RootElement;
                        if (entry.ValueKind != JsonValueKind.Object) {
                            continue;
                        }
                        cwd ??= String(entry, "cwd");
                        if (String(entry, "type") == "session_meta" && entry.TryGetProperty("payload", out var metadata)) {
                            cwd ??= String(metadata, "cwd");
                        }
                        if (String(entry, "type") == "user" && entry.TryGetProperty("message", out var message)) {
                            title ??= String(message, "content");
                        }
                        if (String(entry, "type") == "event_msg" && entry.TryGetProperty("payload", out var payload) && String(payload, "type") == "user_message") {
                            title ??= String(payload, "message");
                        }
                    } catch (JsonException) {
                    }
                }
                var digest = SHA256.HashData(Encoding.UTF8.GetBytes(file.FullName));
                long id = 0;
                for (var i = 0; i < 6; i++) {
                    id = (id << 8) | digest[i];
                }
                var label = title ?? System.IO.Path.GetFileNameWithoutExtension(file.Name);
                label = new string(label.Where(c => !char.IsControl(c)).Take(100).ToArray());
                sessions.Add(new LocalSession(id, provider, label, file.FullName, cwd, file.LastWriteTimeUtc));
            } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
                incomplete = true;
            }
        }
        return new SessionScan(sessions, incomplete);
    }

    private static string? String(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;

    private static bool IsSafePath(string path) {
        for (var current = System.IO.Path.GetFullPath(path); current is not null; current = System.IO.Path.GetDirectoryName(current)) {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) {
                return false;
            }
        }
        return true;
    }
}
