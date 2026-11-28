using System.Text;
using System.Text.Json;

namespace Toki.Core.Claude;

internal sealed record ClaudeCredential(string AccessToken, DateTimeOffset? ExpiresAt, string Source, string? Email);

internal static class ClaudeCredentialReader {
    internal const long MaximumBytes = 256 * 1024;
    internal const string CredentialsFileName = ".credentials.json";

    internal static ClaudeCredential Load(
        AppSettings settings,
        IReadOnlyDictionary<string, string?> environment,
        string homeDirectory,
        DateTimeOffset now) {
        var explicitDirectory = PathHelpers.Clean(settings.ClaudeConfigDirectory);
        if (explicitDirectory is not null) {
            return Read(Path.Combine(ExplicitDirectory(explicitDirectory, homeDirectory), CredentialsFileName), now);
        }
        var environmentDirectory = PathHelpers.Clean(environment.GetValueOrDefault("CLAUDE_CONFIG_DIR"));
        if (environmentDirectory is not null) {
            return Read(Path.Combine(ExplicitDirectory(environmentDirectory, homeDirectory), CredentialsFileName), now);
        }
        var attempts = new List<string>();
        foreach (var directory in CandidateDirectories(environment, homeDirectory)) {
            var path = Path.Combine(directory, CredentialsFileName);
            try {
                return Read(path, now);
            } catch (ProviderException ex) {
                attempts.Add($"{path} ({ex.Message})");
            }
        }
        var lookedIn = attempts.Count == 0 ? "the default Claude Code locations" : string.Join(", ", attempts);
        throw new ProviderException(
            "Couldn't find your Claude Code sign-in. Open Claude Code and run /login, then refresh Toki. Toki looked in " + lookedIn + ".");
    }

    internal static IReadOnlyList<string> CandidateDirectories(
        IReadOnlyDictionary<string, string?> environment,
        string homeDirectory) {
        var directories = new List<string>();
        void Add(string? directory) {
            if (directory is null) {
                return;
            }
            var expanded = PathHelpers.ExpandPath(directory, homeDirectory);
            if (expanded.Length == 0 || !Path.IsPathRooted(expanded) || PathHelpers.HasControlCharacters(expanded)) {
                return;
            }
            if (!directories.Contains(expanded, StringComparer.OrdinalIgnoreCase)) {
                directories.Add(expanded);
            }
        }
        Add(Path.Combine(homeDirectory, ".claude"));
        var xdg = PathHelpers.Clean(environment.GetValueOrDefault("XDG_CONFIG_HOME"));
        if (xdg is not null) {
            Add(Path.Combine(PathHelpers.ExpandPath(xdg, homeDirectory), "claude"));
        }
        Add(Path.Combine(homeDirectory, ".config", "claude"));
        return directories;
    }

    internal static ClaudeCredential Read(string path, DateTimeOffset now) {
        FileInfo info;
        try {
            info = new FileInfo(path);
        } catch (ArgumentException) {
            throw new ProviderException("the path is not valid");
        }
        FileAttributes attributes;
        long length;
        try {
            if (!info.Exists) {
                throw new ProviderException("no such file");
            }
            attributes = info.Attributes;
            length = info.Length;
        } catch (ProviderException) {
            throw;
        } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
            throw new ProviderException("the file couldn't be read (check its permissions)");
        }
        if ((attributes & FileAttributes.Directory) != 0) {
            throw new ProviderException("not a regular file");
        }
        if ((attributes & FileAttributes.ReparsePoint) != 0) {
            throw new ProviderException("a link, so its contents can't be trusted");
        }
        if (length == 0) {
            throw new ProviderException("the file is empty");
        }
        if (length > MaximumBytes) {
            throw new ProviderException("far bigger than a credentials file should be, so it wasn't read");
        }
        string text;
        try {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var buffer = new char[MaximumBytes + 1];
            var read = reader.ReadBlock(buffer, 0, buffer.Length);
            if (read > MaximumBytes) {
                throw new ProviderException("far bigger than a credentials file should be, so it wasn't read");
            }
            text = new string(buffer, 0, read).Trim();
        } catch (ProviderException) {
            throw;
        } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
            throw new ProviderException("the file couldn't be read (check its permissions)");
        }
        if (text.Length == 0) {
            throw new ProviderException("the file is empty");
        }
        return Parse(text, path, now);
    }

    internal static ClaudeCredential Parse(string text, string source, DateTimeOffset now) {
        JsonDocument document;
        try {
            document = JsonDocument.Parse(text);
        } catch (JsonException) {
            throw new ProviderException("Claude Code credentials are not valid JSON");
        }
        using (document) {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) {
                throw new ProviderException("Claude Code credentials are not a JSON object");
            }
            if (!root.TryGetProperty("claudeAiOauth", out var oauth) || oauth.ValueKind != JsonValueKind.Object) {
                throw new ProviderException(
                    "Your Claude Code credentials have no \"claudeAiOauth\" section, which is the subscription sign-in Toki reads usage from. Open Claude Code, run /login, and choose your Claude account. Found instead: " + KeyList(root) + ".");
            }
            if (!oauth.TryGetProperty("accessToken", out var tokenElement) || tokenElement.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(tokenElement.GetString())) {
                throw new ProviderException(
                    "Your Claude Code sign-in has no access token in it. Open Claude Code and run /login again, then refresh Toki. The sign-in holds: " + KeyList(oauth) + ".");
            }
            var expiresAt = JsonHelpers.TryGetDateTimeOffsetFromMilliseconds(oauth, "expiresAt");
            if (expiresAt is not null && expiresAt.Value <= now.AddSeconds(60)) {
                throw new ProviderException("Claude Code sign-in expired. Open Claude Code to sign in again, then refresh Toki.");
            }
            return new ClaudeCredential(tokenElement.GetString()!, expiresAt, source, FindEmail(root, oauth));
        }
    }

    private static string ExplicitDirectory(string rawDirectory, string homeDirectory) {
        var directory = PathHelpers.ExpandPath(rawDirectory, homeDirectory);
        if (!Path.IsPathRooted(directory) || PathHelpers.HasControlCharacters(directory)) {
            throw new ProviderException("The Claude config directory set in Toki settings must be an absolute path.");
        }
        return directory;
    }

    private static string? FindEmail(JsonElement root, JsonElement oauth) {
        foreach (var candidate in new[] { JsonHelpers.TryGetString(oauth, "email"), JsonHelpers.TryGetString(root, "email"), JsonHelpers.TryGetString(root, "accountEmail") }) {
            if (candidate is not null && candidate.Contains('@')) {
                return candidate;
            }
        }
        return null;
    }

    private static string KeyList(JsonElement element) {
        var keys = new List<string>();
        foreach (var property in element.EnumerateObject()) {
            keys.Add(property.Name);
        }
        keys.Sort(StringComparer.Ordinal);
        return keys.Count == 0 ? "nothing" : string.Join(", ", keys);
    }
}
