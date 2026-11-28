using System.Drawing;
using Toki.Windows;

namespace Toki.Core.Tests;

internal static class FlyoutPlacementTests {
    internal static void Run() {
        TestHarness.Run("flyout sits above a bottom tray without covering the taskbar", () => {
            var area = new Rectangle(0, 0, 1920, 1040);
            var result = FlyoutPlacement.Place(area, new Size(400, 490), new Point(1850, 1060), 8);
            TestHarness.True(area.Contains(result), "popup crossed the taskbar");
            TestHarness.Equal(1450, result.Left);
            TestHarness.Equal(1040, result.Bottom);
        });
        TestHarness.Run("flyout opens below a top tray", () => {
            var area = new Rectangle(0, 48, 1920, 1032);
            var result = FlyoutPlacement.Place(area, new Size(400, 490), new Point(1800, 24), 8);
            TestHarness.Equal(48, result.Top);
            TestHarness.True(area.Contains(result), "popup crossed top taskbar");
        });
        TestHarness.Run("flyout fits left and right taskbars", () => {
            var area = new Rectangle(64, 0, 1792, 1080);
            foreach (var anchor in new[] { new Point(20, 900), new Point(1900, 900) }) {
                var result = FlyoutPlacement.Place(area, new Size(400, 490), anchor, 8);
                TestHarness.True(area.Contains(result), "popup crossed side taskbar");
            }
        });
        TestHarness.Run("flyout supports monitors with negative screen coordinates", () => {
            var area = new Rectangle(-1920, -300, 1920, 1040);
            var result = FlyoutPlacement.Place(area, new Size(400, 490), new Point(-80, 760), 8);
            TestHarness.True(area.Contains(result), "popup moved off the selected monitor");
            TestHarness.Equal(-480, result.Left);
        });
        TestHarness.Run("flyout shrinks to fit small high DPI working areas", () => {
            var area = new Rectangle(0, 0, 640, 440);
            var result = FlyoutPlacement.Place(area, new Size(800, 980), new Point(630, 460), 16);
            TestHarness.Equal(area, result);
        });
        TestHarness.Run("flyout clamps stale anchors from another monitor", () => {
            var area = new Rectangle(1920, 0, 1920, 1040);
            var result = FlyoutPlacement.Place(area, new Size(400, 490), new Point(-1900, -1000), 8);
            TestHarness.True(area.Contains(result), "stale cursor put popup off-screen");
        });
    }
}
