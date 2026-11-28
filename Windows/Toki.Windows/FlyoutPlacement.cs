using System.Drawing;

namespace Toki.Windows;

internal static class FlyoutPlacement {
    internal static Rectangle Place(Rectangle workingArea, Size requestedSize, Point anchor, int gap) {
        var width = Math.Clamp(requestedSize.Width, 1, workingArea.Width);
        var height = Math.Clamp(requestedSize.Height, 1, workingArea.Height);
        var left = anchor.X - width;
        var top = anchor.Y - height - gap;
        if (top < workingArea.Top) {
            top = anchor.Y + gap;
        }
        return new Rectangle(
            Math.Clamp(left, workingArea.Left, workingArea.Right - width),
            Math.Clamp(top, workingArea.Top, workingArea.Bottom - height),
            width, height);
    }
}
