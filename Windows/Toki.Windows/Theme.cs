namespace Toki.Windows;

internal static class Theme {
    internal static readonly Color Background = Color.FromArgb(23, 25, 29);
    internal static readonly Color Card = Color.FromArgb(34, 37, 43);
    internal static readonly Color CardHover = Color.FromArgb(42, 46, 53);
    internal static readonly Color Text = Color.FromArgb(244, 241, 234);
    internal static readonly Color MutedText = Color.FromArgb(169, 175, 184);
    internal static readonly Color Sage = Color.FromArgb(142, 169, 155);
    internal static readonly Color Amber = Color.FromArgb(201, 154, 82);
    internal static readonly Color Error = Color.FromArgb(235, 139, 131);
    internal static readonly Color Track = Color.FromArgb(55, 59, 67);

    internal static Button CreateButton(string text, bool primary = false) {
        var button = new Button {
            AutoSize = true,
            BackColor = primary ? Sage : CardHover,
            Cursor = Cursors.Hand,
            FlatStyle = FlatStyle.Flat,
            ForeColor = primary ? Background : Text,
            MinimumSize = new Size(92, 36),
            Padding = new Padding(12, 5, 12, 5),
            Text = text,
            UseVisualStyleBackColor = false
        };
        button.FlatAppearance.BorderSize = 0;
        button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(163, 188, 175) : Color.FromArgb(55, 60, 69);
        return button;
    }

    internal static Label CreateLabel(string text, float fontSize, Color color, bool bold = false) {
        return new Label {
            AutoSize = true,
            Font = new Font("Segoe UI", fontSize, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point),
            ForeColor = color,
            Text = text
        };
    }
}
