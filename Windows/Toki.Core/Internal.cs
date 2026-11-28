namespace Toki.Core;

internal sealed class ProviderException : Exception {
    internal ProviderException(string message) : base(message) { }
}

internal static class PathHelpers {
    internal static string ExpandPath(string path, string homeDirectory) {
        var expanded = Environment.ExpandEnvironmentVariables(path.Trim());
        if (expanded == "~") {
            return homeDirectory;
        }
        if (expanded.StartsWith("~/", StringComparison.Ordinal) || expanded.StartsWith("~\\", StringComparison.Ordinal)) {
            return Path.Combine(homeDirectory, expanded[2..]);
        }
        return expanded;
    }

    internal static bool HasControlCharacters(string value) {
        foreach (var character in value) {
            if (char.IsControl(character)) {
                return true;
            }
        }
        return false;
    }

    internal static string? Clean(string? value) {
        if (string.IsNullOrWhiteSpace(value)) {
            return null;
        }
        return value.Trim();
    }
}

internal static class EnvironmentSnapshot {
    internal static IReadOnlyDictionary<string, string?> Read() {
        var values = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
            if (entry.Key is string key) {
                values[key] = entry.Value as string;
            }
        }
        return values;
    }
}
