using System.Text.Json;

namespace Toki.Core.Claude;

internal static class ClaudeUsageParser {
    internal sealed record ParsedUsage(IReadOnlyList<QuotaWindow> Windows);

    internal static ParsedUsage Parse(string json) {
        JsonDocument document;
        try {
            document = JsonDocument.Parse(json);
        } catch (JsonException) {
            throw new ProviderException("Claude Code usage response was not valid JSON");
        }
        using (document) {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) {
                throw new ProviderException("Claude Code usage response was not a JSON object");
            }
            var windows = new List<QuotaWindow>();
            AppendWindow(root, "five_hour", "5h", windows);
            AppendWindow(root, "seven_day", "7d", windows);
            AppendModelWindows(root, windows);
            if (windows.Count == 0) {
                throw new ProviderException("Claude Code usage unavailable");
            }
            return new ParsedUsage(windows);
        }
    }

    private static void AppendWindow(JsonElement root, string property, string label, List<QuotaWindow> windows) {
        if (!root.TryGetProperty(property, out var window) || window.ValueKind != JsonValueKind.Object) {
            return;
        }
        if (!JsonHelpers.TryGetDouble(window, "utilization", out var utilization)) {
            return;
        }
        windows.Add(new QuotaWindow(label, Math.Clamp(utilization, 0, 100), JsonHelpers.TryGetDateTimeOffset(window, "resets_at")));
    }

    private static void AppendModelWindows(JsonElement root, List<QuotaWindow> windows) {
        if (!root.TryGetProperty("limits", out var limits) || limits.ValueKind != JsonValueKind.Array) {
            return;
        }
        foreach (var entry in limits.EnumerateArray()) {
            if (entry.ValueKind != JsonValueKind.Object || !IsScopedWeekly(entry)) {
                continue;
            }
            var name = ScopeName(entry);
            if (name is null || !JsonHelpers.TryGetDouble(entry, "percent", out var percent)) {
                continue;
            }
            windows.Add(new QuotaWindow(name + " 7d", Math.Clamp(percent, 0, 100), JsonHelpers.TryGetDateTimeOffset(entry, "resets_at")));
        }
    }

    private static bool IsScopedWeekly(JsonElement entry) {
        var kind = JsonHelpers.TryGetString(entry, "kind") ?? string.Empty;
        if (kind == "weekly_all") {
            return false;
        }
        return kind == "weekly_scoped" || kind.StartsWith("weekly", StringComparison.Ordinal) || JsonHelpers.TryGetString(entry, "group") == "weekly";
    }

    private static string? ScopeName(JsonElement entry) {
        if (!entry.TryGetProperty("scope", out var scope)) {
            return null;
        }
        if (scope.ValueKind == JsonValueKind.String) {
            return JsonHelpers.TryGetString(entry, "scope");
        }
        if (scope.ValueKind != JsonValueKind.Object) {
            return null;
        }
        if (scope.TryGetProperty("model", out var model) && model.ValueKind == JsonValueKind.Object) {
            var name = JsonHelpers.TryGetString(model, "display_name");
            if (name is not null) {
                return name;
            }
        }
        return JsonHelpers.TryGetString(scope, "display_name");
    }
}
