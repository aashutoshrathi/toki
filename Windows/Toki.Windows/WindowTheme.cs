using System.Runtime.InteropServices;

namespace Toki.Windows;

internal static class WindowTheme {
    private const int ImmersiveDarkMode = 20;
    private const int CaptionColor = 35;
    private const int TextColor = 36;

    internal static void Apply(IntPtr handle) {
        if (SystemInformation.HighContrast) {
            return;
        }
        Set(handle, ImmersiveDarkMode, 1);
        Set(handle, CaptionColor, ColorTranslator.ToWin32(Theme.Background));
        Set(handle, TextColor, ColorTranslator.ToWin32(Theme.Text));
    }

    internal static void VerifySupportedAttributes(IntPtr handle) {
        if (SystemInformation.HighContrast) {
            return;
        }
        foreach (var (attribute, expected) in new[] {
            (ImmersiveDarkMode, 1),
            (CaptionColor, ColorTranslator.ToWin32(Theme.Background)),
            (TextColor, ColorTranslator.ToWin32(Theme.Text))
        }) {
            if (DwmGetWindowAttribute(handle, attribute, out var actual, sizeof(int)) == 0 && actual != expected) {
                throw new InvalidOperationException($"Window theme attribute {attribute} was not applied.");
            }
        }
    }

    private static void Set(IntPtr handle, int attribute, int value) {
        _ = DwmSetWindowAttribute(handle, attribute, ref value, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
}
