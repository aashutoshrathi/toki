namespace Toki.Windows;

internal static class BrandIcon {
    internal static Icon Load() {
        using var stream = typeof(BrandIcon).Assembly.GetManifestResourceStream("Toki.ico")
            ?? throw new InvalidOperationException("The Toki application icon is missing.");
        using var icon = new Icon(stream);
        return (Icon)icon.Clone();
    }
}
