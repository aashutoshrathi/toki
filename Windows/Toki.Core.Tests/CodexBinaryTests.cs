using Toki.Core.Codex;

namespace Toki.Core.Tests;

internal static class CodexBinaryTests {
    internal static void Run() {
        TestHarness.Run("codex resolver finds codex.exe on PATH", () => {
            using var temp = new TempDirectory();
            var executable = Path.Combine(temp.Path, "codex.exe");
            File.WriteAllText(executable, "fake");
            var launch = CodexBinaryResolver.Resolve(
                new AppSettings(),
                new Dictionary<string, string?> { ["PATH"] = temp.Path },
                temp.Path);
            TestHarness.Equal(executable, launch.ExecutablePath);
            TestHarness.Equal(0, launch.Arguments.Count);
        });

        TestHarness.Run("codex resolver rejects missing explicit executable without fallback", () => {
            using var temp = new TempDirectory();
            var onPath = Path.Combine(temp.Path, "codex.exe");
            File.WriteAllText(onPath, "fake");
            TestHarness.Throws<ProviderException>(
                () => CodexBinaryResolver.Resolve(
                    new AppSettings(CodexExecutable: Path.Combine(temp.Path, "missing.exe")),
                    new Dictionary<string, string?> { ["PATH"] = temp.Path },
                    temp.Path),
                "not found");
        });

        TestHarness.Run("codex resolver rejects cmd shim", () => {
            using var temp = new TempDirectory();
            var shim = Path.Combine(temp.Path, "codex.cmd");
            File.WriteAllText(shim, "@echo off");
            TestHarness.Throws<ProviderException>(
                () => CodexBinaryResolver.Resolve(
                    new AppSettings(CodexExecutable: shim),
                    new Dictionary<string, string?>(),
                    temp.Path),
                ".cmd");
        });

        TestHarness.Run("codex resolver runs explicit js entry with node", () => {
            using var temp = new TempDirectory();
            var node = Path.Combine(temp.Path, "node");
            File.WriteAllText(node, "fake");
            var js = Path.Combine(temp.Path, "codex.js");
            File.WriteAllText(js, "fake");
            var launch = CodexBinaryResolver.Resolve(
                new AppSettings(CodexExecutable: js),
                new Dictionary<string, string?> { ["PATH"] = temp.Path },
                temp.Path);
            TestHarness.Equal(node, launch.ExecutablePath);
            TestHarness.Equal(1, launch.Arguments.Count);
            TestHarness.Equal(js, launch.Arguments[0]);
        });

        TestHarness.Run("codex resolver finds npm js entry with node", () => {
            using var temp = new TempDirectory();
            var npmRoot = Path.Combine(temp.Path, "npm");
            var package = Path.Combine(npmRoot, "node_modules", "@openai", "codex");
            Directory.CreateDirectory(Path.Combine(package, "bin"));
            var js = Path.Combine(package, "bin", "codex.js");
            File.WriteAllText(js, "fake");
            var node = Path.Combine(temp.Path, "node");
            File.WriteAllText(node, "fake");
            var launch = CodexBinaryResolver.Resolve(
                new AppSettings(),
                new Dictionary<string, string?> { ["PATH"] = temp.Path, ["APPDATA"] = temp.Path },
                temp.Path);
            TestHarness.Equal(node, launch.ExecutablePath);
            TestHarness.Equal(js, launch.Arguments[0]);
        });

        TestHarness.Run("codex resolver prefers npm native vendor binary", () => {
            using var temp = new TempDirectory();
            var npmRoot = Path.Combine(temp.Path, "npm");
            var package = Path.Combine(npmRoot, "node_modules", "@openai", "codex");
            var native = Path.Combine(
                npmRoot,
                "node_modules",
                "@openai",
                "codex-win32-x64",
                "vendor",
                "x86_64-pc-windows-msvc",
                "bin",
                "codex.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(native)!);
            File.WriteAllText(native, "fake");
            Directory.CreateDirectory(Path.Combine(package, "bin"));
            File.WriteAllText(Path.Combine(package, "bin", "codex.js"), "fake");
            var launch = CodexBinaryResolver.Resolve(
                new AppSettings(),
                new Dictionary<string, string?> { ["PATH"] = temp.Path, ["APPDATA"] = temp.Path },
                temp.Path);
            TestHarness.Equal(native, launch.ExecutablePath);
        });

        TestHarness.Run("codex resolver finds npm package beside custom PATH shim", () => {
            using var temp = new TempDirectory();
            var prefix = Path.Combine(temp.Path, "custom-node");
            var package = Path.Combine(prefix, "node_modules", "@openai", "codex", "bin");
            Directory.CreateDirectory(package);
            var js = Path.Combine(package, "codex.js");
            File.WriteAllText(js, "fake");
            var node = Path.Combine(prefix, "node.exe");
            File.WriteAllText(node, "fake");
            File.WriteAllText(Path.Combine(prefix, "codex.cmd"), "fake");
            var launch = CodexBinaryResolver.Resolve(new AppSettings(),
                new Dictionary<string, string?> { ["PATH"] = prefix }, temp.Path);
            TestHarness.Equal(node, launch.ExecutablePath);
            TestHarness.Equal(js, launch.Arguments[0]);
        });

        TestHarness.Run("codex resolver reports not installed", () => {
            using var temp = new TempDirectory();
            TestHarness.Throws<ProviderException>(
                () => CodexBinaryResolver.Resolve(
                    new AppSettings(),
                    new Dictionary<string, string?> { ["PATH"] = temp.Path },
                    temp.Path),
                "isn't installed");
        });

        TestHarness.Run("codex home prefers explicit setting", () => {
            using var temp = new TempDirectory();
            var explicitHome = Path.Combine(temp.Path, "explicit");
            var home = CodexBinaryResolver.CodexHome(
                new AppSettings(CodexHome: explicitHome),
                new Dictionary<string, string?> { ["CODEX_HOME"] = Path.Combine(temp.Path, "env") },
                temp.Path);
            TestHarness.Equal(explicitHome, home);
        });

        TestHarness.Run("codex home uses environment then default", () => {
            using var temp = new TempDirectory();
            var environmentHome = Path.Combine(temp.Path, "env");
            TestHarness.Equal(
                environmentHome,
                CodexBinaryResolver.CodexHome(
                    new AppSettings(),
                    new Dictionary<string, string?> { ["CODEX_HOME"] = environmentHome },
                    temp.Path));
            TestHarness.Equal(
                Path.Combine(temp.Path, ".codex"),
                CodexBinaryResolver.CodexHome(new AppSettings(), new Dictionary<string, string?>(), temp.Path));
        });

        TestHarness.Run("codex home rejects relative explicit setting", () => {
            using var temp = new TempDirectory();
            TestHarness.Throws<ProviderException>(
                () => CodexBinaryResolver.CodexHome(
                    new AppSettings(CodexHome: "relative"),
                    new Dictionary<string, string?>(),
                    temp.Path),
                "absolute path");
        });
    }
}
