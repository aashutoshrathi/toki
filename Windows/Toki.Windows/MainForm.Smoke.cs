using Toki.Core;

namespace Toki.Windows;

internal sealed partial class MainForm {
    private int _smokeStep;
    private SettingsDialog? _smokeSettings;

    private void StartSmokeTest() {
        RenderSnapshots(new[] {
            new ProviderSnapshot("claude-code", "Claude Code", "Offline fixture", new[] {
                new QuotaWindow("5h", 25, DateTimeOffset.UtcNow.AddHours(2)),
                new QuotaWindow("7d", 80, DateTimeOffset.UtcNow.AddDays(3))
            }, null, DateTimeOffset.UtcNow),
            new ProviderSnapshot("codex", "Codex", "Offline fixture", new[] {
                new QuotaWindow("5h", 40, DateTimeOffset.UtcNow.AddHours(4)),
                new QuotaWindow("7d", 15, DateTimeOffset.UtcNow.AddDays(6))
            }, null, DateTimeOffset.UtcNow)
        });
        _statusLabel.Text = "Smoke test fixtures - not live usage.";
        ShowFlyout();
        Require(!Visible, "Startup must not show the full dashboard.");
        _smokeTimer = new System.Windows.Forms.Timer { Interval = 400 };
        _smokeTimer.Tick += (_, _) => RunSmokeStep();
        _smokeTimer.Start();
    }

    private void RunSmokeStep() {
        switch (_smokeStep++) {
            case 0:
                Require(_flyout.Visible && !_flyout.ShowInTaskbar, "Compact usage must be visible without a taskbar button.");
                Require(Screen.FromControl(_flyout).WorkingArea.Contains(_flyout.Bounds), "Flyout must fit within the display working area.");
                VerifyFlyoutContent();
                SaveSmokeImage(_flyout, "TOKI_SMOKE_FLYOUT_SCREENSHOT");
                ShowDashboard();
                break;
            case 1:
                Require(Visible && !_flyout.Visible, "Dashboard action must switch to the full dashboard.");
                WindowTheme.VerifySupportedAttributes(Handle);
                SaveSmokeImage(this, "TOKI_SMOKE_SCREENSHOT");
                Close();
                Require(!IsDisposed && !Visible, "Dashboard X must hide to tray rather than exit.");
                _smokeSettings = new SettingsDialog(new AppSettings());
                _smokeSettings.Show();
                break;
            case 2:
                WindowTheme.VerifySupportedAttributes(_smokeSettings!.Handle);
                SaveSmokeImage(_smokeSettings, "TOKI_SMOKE_SETTINGS_SCREENSHOT");
                _smokeSettings.Close();
                _smokeSettings.Dispose();
                _smokeSettings = null;
                RenderSnapshots(new[] {
                    new ProviderSnapshot("codex", "Codex", "Offline fixture", Array.Empty<QuotaWindow>(), "Test connection error - no quota available.", DateTimeOffset.UtcNow)
                });
                ShowFlyout();
                break;
            case 3:
                Require(_flyout.Visible && !Visible, "Reopening usage must keep the dashboard hidden.");
                Show();
                Activate();
                break;
            case 4:
                Require(!_flyout.Visible, "Clicking away must dismiss the usage panel.");
                HideDashboard();
                _smokeTimer!.Stop();
                ExitApplication();
                break;
        }
    }

    private static void Require(bool condition, string message) {
        if (!condition) {
            throw new InvalidOperationException(message);
        }
    }

    private void VerifyFlyoutContent() {
        var controls = Descendants(_flyout).ToArray();
        foreach (var text in new[] { "Claude Code", "Codex", "75% left", "20% left", "60% left", "85% left" }) {
            var label = controls.OfType<Label>().Single(control => control.Text == text);
            Require(label.Visible && label.Width >= label.PreferredWidth, $"Flyout label '{text}' must be readable.");
            for (Control? child = label; child?.Parent is { } parent; child = parent) {
                Require(parent.ClientRectangle.Contains(child.Bounds), $"Flyout label '{text}' must not be clipped.");
            }
        }
        var bars = controls.OfType<QuotaBar>().ToArray();
        Require(bars.Length == 4 && bars.All(bar => bar.Visible && bar.Width >= _flyout.LogicalToDeviceUnits(200)), "All four fixture quota bars must be visible at usable widths.");
    }

    private static IEnumerable<Control> Descendants(Control root) {
        foreach (Control child in root.Controls) {
            yield return child;
            foreach (var descendant in Descendants(child)) {
                yield return descendant;
            }
        }
    }

    private static void SaveSmokeImage(Form form, string variable) {
        var path = Environment.GetEnvironmentVariable(variable);
        if (!string.IsNullOrWhiteSpace(path)) {
            using var bitmap = new Bitmap(form.Width, form.Height);
            form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
