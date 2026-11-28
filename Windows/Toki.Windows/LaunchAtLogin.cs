using Microsoft.Win32;

namespace Toki.Windows;

internal static class LaunchAtLogin {
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string ValueName = "Toki Windows Preview";

    internal static bool IsRegistered() {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(ValueName) is string;
    }

    internal static void SetEnabled(bool enabled) {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        SetRegistration(key, enabled, Application.ExecutablePath);
    }

    internal static void SetRegistration(RegistryKey key, bool enabled, string executable) {
        if (!enabled) {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            return;
        }
        var command = $"\"{executable}\" --background";
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)
            || executable.Contains('"') || command.Length > 260) {
            throw new InvalidOperationException("Move Toki to a shorter permanent path before enabling startup.");
        }
        key.SetValue(ValueName, command, RegistryValueKind.String);
    }
}
