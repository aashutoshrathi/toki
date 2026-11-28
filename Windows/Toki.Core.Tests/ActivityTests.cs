using System.Text.Json;

namespace Toki.Core.Tests;

internal static class ActivityTests {
    internal static void Run() {
        var now = DateTimeOffset.UtcNow;
        ProviderSnapshot Reading(double used, DateTimeOffset? reset, string? error = null) => new("claude", "Claude", "", [new("5h", used, reset)], error, now);
        TestHarness.Run("session quota burn and reset boundary", () => {
            var tracker = new ActivityTracker();
            tracker.Start([Reading(20, now.AddHours(1))], now);
            TestHarness.True(tracker.Describe([Reading(35, now.AddHours(1))], now).Contains("15 percentage points"), "quota delta should be measured");
            TestHarness.True(tracker.Describe([Reading(3, now.AddHours(6))], now).Contains("window reset"), "reset must not be counted as burn");
            TestHarness.True(tracker.Describe([Reading(35, now.AddHours(1), "error")], now).Contains("unavailable"), "errors must hide burn");
            tracker.Stop([Reading(35, now.AddHours(1))], now.AddMinutes(1));
            TestHarness.True(tracker.StartedAt is null && tracker.Events.Count == 2, "session should stop and record summary");
        });
        TestHarness.Run("session reset without timestamp remains invalid after quota rises again", () => {
            var tracker = new ActivityTracker();
            tracker.Start([Reading(20, null)], now);
            tracker.Observe([Reading(35, null)], now);
            tracker.Observe([Reading(25, null)], now);
            tracker.Observe([Reading(40, null)], now);
            TestHarness.True(tracker.Describe([Reading(40, null)], now).Contains("window reset"), "a detected reset must not later produce false burn");
        });
        TestHarness.Run("events record provider transitions without repeated errors", () => {
            var tracker = new ActivityTracker();
            tracker.Observe([Reading(10, null, "failed")], now);
            tracker.Observe([Reading(10, null, "failed")], now);
            tracker.Observe([Reading(10, null)], now);
            TestHarness.Equal(2, tracker.Events.Count);
            for (var i = 0; i < 250; i++) {
                tracker.Record("Test", "event", now);
            }
            TestHarness.Equal(200, tracker.Events.Count);
            tracker.ClearEvents();
            TestHarness.Equal(0, tracker.Events.Count);
        });
        TestHarness.Run("session does not use stale baseline or stale current readings", () => {
            var tracker = new ActivityTracker();
            tracker.Start([Reading(20, null)], now.AddMinutes(5));
            TestHarness.True(tracker.Describe([Reading(30, null)], now.AddMinutes(5)).Contains("No comparable"), "old baseline must be ignored");
            tracker.Stop([], now);
            tracker.Start([Reading(20, null)], now);
            TestHarness.True(tracker.Describe([Reading(30, null)], now.AddMinutes(5)).Contains("unavailable"), "old current reading must be ignored");
        });
        TestHarness.Run("recent session discovery uses configured roots and stable IDs", () => {
            using var temporary = new TempDirectory();
            var root = OperatingSystem.IsMacOS() ? temporary.Path.Replace("/var/", "/private/var/") : temporary.Path;
            var claude = Path.Combine(root, "claude");
            var codex = Path.Combine(root, "codex");
            var projects = Path.Combine(claude, "projects", "project");
            var sessions = Path.Combine(codex, "sessions", "2026", "11", "28");
            Directory.CreateDirectory(projects);
            Directory.CreateDirectory(sessions);
            File.WriteAllText(Path.Combine(projects, "claude.jsonl"), JsonSerializer.Serialize(new { type = "user", cwd = "C:\\work", message = new { content = "Fix a test" } }) + "\n");
            File.WriteAllText(Path.Combine(sessions, "codex.jsonl"), "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"C:\\\\work\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Review code\"}}\n");
            var first = SessionCatalog.ScanRoots(claude, codex, CancellationToken.None);
            TestHarness.Equal(2, first.Sessions.Count);
            TestHarness.True(first.Sessions.Any(s => s.Title == "Fix a test") && first.Sessions.Any(s => s.Title == "Review code"), "both provider titles should parse");
            var second = SessionCatalog.ScanRoots(claude, codex, CancellationToken.None);
            TestHarness.Equal(string.Join(',', first.Sessions.Select(s => s.Id)), string.Join(',', second.Sessions.Select(s => s.Id)));
            using (var file = File.Create(Path.Combine(projects, "huge.jsonl"))) {
                file.SetLength(SessionCatalog.MaximumFileSize + 1);
            }
            var bounded = SessionCatalog.ScanRoots(claude, codex, CancellationToken.None);
            TestHarness.Equal(2, bounded.Sessions.Count);
            TestHarness.True(bounded.Incomplete, "oversized history must be reported");
            TestHarness.Throws<OperationCanceledException>(() => SessionCatalog.ScanRoots(claude, codex, new CancellationToken(true)), "cancel");
        });
    }
}
