namespace Toki.Core.Tests;

internal static class TestHarness {
    private static int _passed;
    private static int _failed;

    internal static void Run(string name, Action test) {
        try {
            test();
            Pass(name);
        } catch (Exception ex) {
            Fail(name, ex);
        }
    }

    internal static async Task RunAsync(string name, Func<Task> test) {
        try {
            await test();
            Pass(name);
        } catch (Exception ex) {
            Fail(name, ex);
        }
    }

    internal static void Equal<T>(T expected, T actual, string? what = null) {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) {
            throw new Exception((what ?? "value") + ": expected <" + expected + "> but got <" + actual + ">");
        }
    }

    internal static void True(bool condition, string message) {
        if (!condition) {
            throw new Exception(message);
        }
    }

    internal static void Throws<T>(Action action, string contains) where T : Exception {
        try {
            action();
        } catch (T ex) {
            if (!ex.Message.Contains(contains, StringComparison.OrdinalIgnoreCase)) {
                throw new Exception("expected message containing \"" + contains + "\" but got \"" + ex.Message + "\"");
            }
            return;
        }
        throw new Exception("expected " + typeof(T).Name + " but nothing was thrown");
    }

    internal static async Task ThrowsAsync<T>(Func<Task> action, string contains) where T : Exception {
        try {
            await action();
        } catch (T ex) {
            if (!ex.Message.Contains(contains, StringComparison.OrdinalIgnoreCase)) {
                throw new Exception("expected message containing \"" + contains + "\" but got \"" + ex.Message + "\"");
            }
            return;
        }
        throw new Exception("expected " + typeof(T).Name + " but nothing was thrown");
    }

    internal static int Finish() {
        Console.WriteLine();
        Console.WriteLine($"{_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }

    private static void Pass(string name) {
        _passed++;
        Console.WriteLine("PASS " + name);
    }

    private static void Fail(string name, Exception ex) {
        _failed++;
        Console.WriteLine("FAIL " + name + ": " + ex.Message);
    }
}

internal sealed class TempDirectory : IDisposable {
    internal string Path { get; }

    internal TempDirectory() {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "toki-core-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public void Dispose() {
        try {
            Directory.Delete(Path, true);
        } catch (IOException) {
        } catch (UnauthorizedAccessException) {
        }
    }
}
