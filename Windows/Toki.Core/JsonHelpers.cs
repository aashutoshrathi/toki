using System.Globalization;
using System.Text.Json;

namespace Toki.Core;

internal static class JsonHelpers {
    internal static bool TryGetDouble(JsonElement element, string property, out double value) {
        value = 0;
        if (!element.TryGetProperty(property, out var raw)) {
            return false;
        }
        switch (raw.ValueKind) {
            case JsonValueKind.Number:
                return raw.TryGetDouble(out value) && double.IsFinite(value);
            case JsonValueKind.String:
                return double.TryParse(raw.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out value) && double.IsFinite(value);
            default:
                return false;
        }
    }

    internal static string? TryGetString(JsonElement element, string property) {
        if (!element.TryGetProperty(property, out var raw) || raw.ValueKind != JsonValueKind.String) {
            return null;
        }
        var value = raw.GetString();
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    internal static DateTimeOffset? TryGetDateTimeOffset(JsonElement element, string property) {
        if (!element.TryGetProperty(property, out var raw)) {
            return null;
        }
        if (raw.ValueKind == JsonValueKind.String) {
            var text = raw.GetString();
            if (string.IsNullOrWhiteSpace(text)) {
                return null;
            }
            if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)) {
                return parsed;
            }
            return null;
        }
        if (raw.ValueKind == JsonValueKind.Number && raw.TryGetDouble(out var seconds)) {
            return FromUnixSeconds(seconds);
        }
        return null;
    }

    internal static DateTimeOffset? TryGetDateTimeOffsetFromMilliseconds(JsonElement element, string property) {
        if (!TryGetDouble(element, property, out var milliseconds)) {
            return null;
        }
        if (milliseconds <= 0 || milliseconds > 253402300799999) {
            return null;
        }
        return DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds);
    }

    internal static DateTimeOffset? FromUnixSeconds(double seconds) {
        if (seconds <= 0 || seconds > 253402300799) {
            return null;
        }
        return DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
    }
}
