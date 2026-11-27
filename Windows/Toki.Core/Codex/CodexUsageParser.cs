using System.Text.Json;

namespace Toki.Core.Codex;

internal sealed record CodexAppServerPayload(JsonElement? RateLimits, JsonElement? Account);

internal static class CodexUsageParser {
    internal sealed record ParsedUsage(IReadOnlyList<QuotaWindow> Windows, string Detail);

    internal static ParsedUsage Parse(JsonElement? rateLimits, JsonElement? account) {
        if (rateLimits is not { ValueKind: JsonValueKind.Object } root) {
            throw new ProviderException("Codex usage unavailable");
        }
        var limits = PreferredLimits(root);
        var windows = new List<QuotaWindow>();
        AppendWindow(limits, "primary", "5h", windows);
        AppendWindow(limits, "secondary", "7d", windows);
        if (windows.Count == 0) {
            throw new ProviderException("Codex usage unavailable");
        }
        var plan = JsonHelpers.TryGetString(limits, "planType");
        var email = AccountEmail(account);
        var detail = plan is not null
            ? "OpenAI Codex - " + plan
            : email ?? "OpenAI Codex rate limits";
        return new ParsedUsage(windows, detail);
    }

    private static JsonElement PreferredLimits(JsonElement root) {
        if (root.TryGetProperty("rateLimitsByLimitId", out var byId)
            && byId.ValueKind == JsonValueKind.Object
            && byId.TryGetProperty("codex", out var codex)
            && codex.ValueKind == JsonValueKind.Object) {
            return codex;
        }
        if (root.TryGetProperty("rateLimits", out var limits) && limits.ValueKind == JsonValueKind.Object) {
            return limits;
        }
        return root;
    }

    private static void AppendWindow(JsonElement limits, string property, string fallbackLabel, List<QuotaWindow> windows) {
        if (!limits.TryGetProperty(property, out var window) || window.ValueKind != JsonValueKind.Object) {
            return;
        }
        if (!JsonHelpers.TryGetDouble(window, "usedPercent", out var usedPercent)) {
            return;
        }
        windows.Add(new QuotaWindow(
            WindowLabel(window, fallbackLabel),
            Math.Clamp(usedPercent, 0, 100),
            JsonHelpers.TryGetDateTimeOffset(window, "resetsAt")));
    }

    private static string WindowLabel(JsonElement window, string fallback) {
        if (!JsonHelpers.TryGetDouble(window, "windowDurationMins", out var minutes)) {
            return fallback;
        }
        if (minutes == 300) {
            return "5h";
        }
        if (minutes == 10080) {
            return "7d";
        }
        if (minutes >= 1440) {
            return (int)(minutes / 1440) + "d";
        }
        if (minutes >= 60) {
            return (int)(minutes / 60) + "h";
        }
        return (int)minutes + "m";
    }

    private static string? AccountEmail(JsonElement? account) {
        if (account is not { ValueKind: JsonValueKind.Object } root) {
            return null;
        }
        if (!root.TryGetProperty("account", out var accountObject) || accountObject.ValueKind != JsonValueKind.Object) {
            return null;
        }
        return JsonHelpers.TryGetString(accountObject, "email");
    }
}
