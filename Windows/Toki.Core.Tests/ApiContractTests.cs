using System.Reflection;

namespace Toki.Core.Tests;

internal static class ApiContractTests {
    internal static void Run() {
        TestHarness.Run("api contract app settings defaults", () => {
            var settings = new AppSettings();
            TestHarness.Equal<string?>(null, settings.ClaudeConfigDirectory);
            TestHarness.Equal<string?>(null, settings.CodexHome);
            TestHarness.Equal<string?>(null, settings.CodexExecutable);
            TestHarness.True(settings.NotificationsEnabled, "notifications should default on");
            TestHarness.True(!settings.DoNotDisturb, "do not disturb should default off");
            TestHarness.True(typeof(AppSettings).IsSealed, "AppSettings should be sealed");
        });

        TestHarness.Run("api contract quota window properties", () => {
            TestHarness.True(typeof(QuotaWindow).IsSealed, "QuotaWindow should be sealed");
            var properties = typeof(QuotaWindow).GetProperties().Select(property => property.Name).OrderBy(name => name);
            TestHarness.Equal("Label,RemainingPercent,ResetsAt,UsedPercent", string.Join(",", properties));
        });

        TestHarness.Run("api contract provider snapshot properties", () => {
            TestHarness.True(typeof(ProviderSnapshot).IsSealed, "ProviderSnapshot should be sealed");
            var properties = typeof(ProviderSnapshot).GetProperties().Select(property => property.Name).OrderBy(name => name);
            TestHarness.Equal("CheckedAt,Detail,Error,Id,Name,Windows", string.Join(",", properties));
        });

        TestHarness.Run("api contract usage reader signature", () => {
            var refresh = typeof(UsageReader).GetMethod("RefreshAsync", BindingFlags.Public | BindingFlags.Static);
            TestHarness.True(refresh is not null, "RefreshAsync should be public static");
            TestHarness.Equal(typeof(Task<IReadOnlyList<ProviderSnapshot>>), refresh!.ReturnType);
            var parameters = refresh.GetParameters();
            TestHarness.Equal(2, parameters.Length);
            TestHarness.Equal(typeof(AppSettings), parameters[0].ParameterType);
            TestHarness.Equal(typeof(CancellationToken), parameters[1].ParameterType);
        });

        TestHarness.Run("api contract settings store signature", () => {
            var directory = typeof(SettingsStore).GetProperty("DirectoryPath", BindingFlags.Public | BindingFlags.Static);
            TestHarness.True(directory is not null, "DirectoryPath should be public static");
            TestHarness.Equal(typeof(string), directory!.PropertyType);
            TestHarness.True(
                typeof(SettingsStore).GetMethod("Load", BindingFlags.Public | BindingFlags.Static) is not null,
                "Load should be public static");
            TestHarness.True(
                typeof(SettingsStore).GetMethod("Save", BindingFlags.Public | BindingFlags.Static) is not null,
                "Save should be public static");
        });
    }
}
