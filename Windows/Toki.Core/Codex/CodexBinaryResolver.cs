namespace Toki.Core.Codex;

internal sealed record CodexLaunch(
    string ExecutablePath,
    IReadOnlyList<string> Arguments,
    string Source,
    IReadOnlyDictionary<string, string>? Environment = null);

internal static class CodexBinaryResolver {
    internal const string NotFoundMessage =
        "Codex isn't installed where Toki can run it. Install the Codex CLI so `codex` is on your PATH, or set the Codex executable in Toki settings.";

    internal static CodexLaunch Resolve(
        AppSettings settings,
        IReadOnlyDictionary<string, string?> environment,
        string homeDirectory) {
        var explicitPath = PathHelpers.Clean(settings.CodexExecutable);
        if (explicitPath is not null) {
            return ResolveExplicit(explicitPath, environment, homeDirectory);
        }
        foreach (var directory in SearchDirectories(environment)) {
            var candidate = Path.Combine(directory, "codex.exe");
            if (IsRegularFile(candidate)) {
                return new CodexLaunch(candidate, Array.Empty<string>(), "PATH " + candidate);
            }
        }
        foreach (var packageDirectory in NpmPackageDirectories(environment, homeDirectory)) {
            var native = FindNativeVendorBinary(packageDirectory);
            if (native is not null) {
                return new CodexLaunch(native, Array.Empty<string>(), "npm " + native);
            }
            var js = Path.Combine(packageDirectory, "bin", "codex.js");
            if (IsRegularFile(js)) {
                var node = FindNode(environment);
                if (node is not null) {
                    return new CodexLaunch(node, new[] { js }, "npm " + js);
                }
            }
        }
        throw new ProviderException(NotFoundMessage);
    }

    internal static string CodexHome(AppSettings settings, IReadOnlyDictionary<string, string?> environment, string homeDirectory) {
        var explicitHome = PathHelpers.Clean(settings.CodexHome);
        if (explicitHome is not null) {
            return RequireAbsoluteDirectory(explicitHome, homeDirectory, "The Codex home set in Toki settings");
        }
        var environmentHome = PathHelpers.Clean(environment.GetValueOrDefault("CODEX_HOME"));
        if (environmentHome is not null) {
            return RequireAbsoluteDirectory(environmentHome, homeDirectory, "CODEX_HOME");
        }
        return Path.Combine(homeDirectory, ".codex");
    }

    internal static IReadOnlyList<string> SearchDirectories(IReadOnlyDictionary<string, string?> environment) {
        var path = environment.GetValueOrDefault("PATH");
        if (string.IsNullOrWhiteSpace(path)) {
            return Array.Empty<string>();
        }
        var directories = new List<string>();
        foreach (var entry in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)) {
            var directory = entry.Trim().Trim('"');
            if (!Path.IsPathFullyQualified(directory) || PathHelpers.HasControlCharacters(directory)) {
                continue;
            }
            if (!directories.Contains(directory, StringComparer.OrdinalIgnoreCase)) {
                directories.Add(directory);
            }
        }
        return directories;
    }

    internal static IReadOnlyList<string> NpmPackageDirectories(IReadOnlyDictionary<string, string?> environment, string homeDirectory) {
        var directories = new List<string>();
        void Add(string? root) {
            if (root is null) {
                return;
            }
            var directory = Path.Combine(root, "node_modules", "@openai", "codex");
            if (!directories.Contains(directory, StringComparer.OrdinalIgnoreCase)) {
                directories.Add(directory);
            }
        }
        var appData = PathHelpers.Clean(environment.GetValueOrDefault("APPDATA"));
        if (appData is not null) {
            Add(Path.Combine(appData, "npm"));
        }
        foreach (var directory in SearchDirectories(environment)) {
            Add(directory);
        }
        Add(PathHelpers.Clean(environment.GetValueOrDefault("npm_config_prefix")));
        Add(Path.Combine(homeDirectory, "AppData", "Roaming", "npm"));
        Add(PathHelpers.Clean(environment.GetValueOrDefault("ProgramFiles")) is { } programFiles
            ? Path.Combine(programFiles, "nodejs")
            : null);
        return directories;
    }

    internal static string? FindNode(IReadOnlyDictionary<string, string?> environment) {
        foreach (var directory in SearchDirectories(environment)) {
            foreach (var name in new[] { "node.exe", "node" }) {
                var candidate = Path.Combine(directory, name);
                if (IsRegularFile(candidate)) {
                    return candidate;
                }
            }
        }
        foreach (var root in new[] {
                     PathHelpers.Clean(environment.GetValueOrDefault("ProgramFiles")),
                     PathHelpers.Clean(environment.GetValueOrDefault("ProgramFiles(x86)"))
                 }) {
            if (root is null) {
                continue;
            }
            var candidate = Path.Combine(root, "nodejs", "node.exe");
            if (IsRegularFile(candidate)) {
                return candidate;
            }
        }
        return null;
    }

    internal static bool IsRegularFile(string path) {
        try {
            if (!File.Exists(path)) {
                return false;
            }
            return (File.GetAttributes(path) & FileAttributes.Directory) == 0;
        } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) {
            return false;
        }
    }

    private static CodexLaunch ResolveExplicit(
        string rawPath,
        IReadOnlyDictionary<string, string?> environment,
        string homeDirectory) {
        var path = PathHelpers.ExpandPath(rawPath, homeDirectory);
        if (!Path.IsPathRooted(path) || PathHelpers.HasControlCharacters(path)) {
            throw new ProviderException("The Codex executable set in Toki settings must be an absolute path.");
        }
        var extension = Path.GetExtension(path);
        if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase) || extension.Equals(".bat", StringComparison.OrdinalIgnoreCase)) {
            throw new ProviderException(
                "Toki cannot run a .cmd or .bat shim directly. Set the Codex executable to codex.exe or the npm codex.js entry instead.");
        }
        if (!IsRegularFile(path)) {
            throw new ProviderException("The Codex executable set in Toki settings was not found: " + path);
        }
        if (extension.Equals(".js", StringComparison.OrdinalIgnoreCase)
            || extension.Equals(".mjs", StringComparison.OrdinalIgnoreCase)
            || extension.Equals(".cjs", StringComparison.OrdinalIgnoreCase)) {
            var node = FindNode(environment)
                ?? throw new ProviderException("The Codex executable set in Toki settings is a JavaScript entry, but Node.js was not found on PATH.");
            return new CodexLaunch(node, new[] { path }, "settings " + path);
        }
        return new CodexLaunch(path, Array.Empty<string>(), "settings " + path);
    }

    private static string RequireAbsoluteDirectory(string rawDirectory, string homeDirectory, string label) {
        var directory = PathHelpers.ExpandPath(rawDirectory, homeDirectory);
        if (!Path.IsPathRooted(directory) || PathHelpers.HasControlCharacters(directory)) {
            throw new ProviderException(label + " must be an absolute path.");
        }
        return directory;
    }

    private static string? FindNativeVendorBinary(string packageDirectory) {
        var platformPackage = Path.GetFullPath(Path.Combine(packageDirectory, "..", "codex-win32-x64"));
        var nestedPlatformPackage = Path.Combine(packageDirectory, "node_modules", "@openai", "codex-win32-x64");
        var candidates = new[] {
            Path.Combine(platformPackage, "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
            Path.Combine(nestedPlatformPackage, "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
            Path.Combine(packageDirectory, "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
            Path.Combine(platformPackage, "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe"),
            Path.Combine(nestedPlatformPackage, "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe"),
            Path.Combine(packageDirectory, "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe"),
            Path.Combine(platformPackage, "codex.exe"),
            Path.Combine(packageDirectory, "bin", "codex.exe")
        };
        foreach (var candidate in candidates) {
            if (IsRegularFile(candidate)) {
                return candidate;
            }
        }
        return null;
    }
}
