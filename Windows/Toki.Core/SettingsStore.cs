using System.Text.Json;

namespace Toki.Core;

public sealed class SettingsException : Exception {
    public SettingsException(string message) : base(message) { }
}

public static class SettingsStore {
    internal const long MaximumSettingsBytes = 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip
    };

    public static string DirectoryPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Toki");

    internal static string FilePath => Path.Combine(DirectoryPath, "windows-settings.json");

    public static AppSettings Load() => LoadFrom(FilePath);

    public static void Save(AppSettings settings) => SaveTo(FilePath, settings);

    internal static AppSettings LoadFrom(string path) {
        if (!File.Exists(path)) {
            return new AppSettings();
        }
        string text;
        try {
            var info = new FileInfo(path);
            if (info.Length > MaximumSettingsBytes) {
                throw new SettingsException($"Toki settings at {path} are too large to be a settings file. Toki did not change it.");
            }
            text = File.ReadAllText(path);
        } catch (SettingsException) {
            throw;
        } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
            throw new SettingsException($"Toki could not read its settings at {path}. Toki did not change it.");
        }
        AppSettings? parsed;
        try {
            parsed = JsonSerializer.Deserialize<AppSettings>(text, JsonOptions);
        } catch (JsonException) {
            throw new SettingsException($"Toki settings at {path} are not valid JSON. Fix or delete the file; Toki did not change it.");
        }
        if (parsed is null) {
            throw new SettingsException($"Toki settings at {path} are empty. Fix or delete the file; Toki did not change it.");
        }
        return Normalize(parsed);
    }

    internal static void SaveTo(string path, AppSettings settings) {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) {
            Directory.CreateDirectory(directory);
        }
        var json = JsonSerializer.Serialize(Normalize(settings), JsonOptions);
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                using var writer = new StreamWriter(stream);
                writer.Write(json);
                writer.Flush();
                stream.Flush(true);
            }
            File.Move(temp, path, true);
        } finally {
            if (File.Exists(temp)) {
                try {
                    File.Delete(temp);
                } catch (IOException) {
                } catch (UnauthorizedAccessException) {
                }
            }
        }
    }

    internal static AppSettings Normalize(AppSettings settings) => settings with {
        ClaudeConfigDirectory = PathHelpers.Clean(settings.ClaudeConfigDirectory),
        CodexHome = PathHelpers.Clean(settings.CodexHome),
        CodexExecutable = PathHelpers.Clean(settings.CodexExecutable)
    };
}
