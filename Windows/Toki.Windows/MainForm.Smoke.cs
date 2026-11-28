using Toki.Core;

namespace Toki.Windows;

internal sealed partial class MainForm {
    private int _smokeStep;
    private int _remoteSmokeWait;
    private Task? _remoteSmokeCheck;
    private SettingsDialog? _smokeSettings;

    private void StartSmokeTest() {
        Require(!Visible && _flyout.Visible != _background, "Startup visibility must respect --background.");
        VerifyStartupRegistration();
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
                _smokeSettings = new SettingsDialog(new AppSettings(), false);
                _smokeSettings.Show();
                break;
            case 2:
                WindowTheme.VerifySupportedAttributes(_smokeSettings!.Handle);
                foreach (var control in Descendants(_smokeSettings).Where(c => c is CheckBox or Button)) {
                    Require(control.Visible, "All settings options must be visible.");
                    for (Control? child = control; child?.Parent is { } parent; child = parent) {
                        Require(parent.ClientRectangle.Contains(child.Bounds), "Settings options must not be clipped.");
                    }
                }
                SaveSmokeImage(_smokeSettings, "TOKI_SMOKE_SETTINGS_SCREENSHOT");
                _smokeSettings.Close();
                _smokeSettings.Dispose();
                _smokeSettings = null;
                RenderSnapshots(new[] {
                    new ProviderSnapshot("codex", "Codex", "private@example.test", Array.Empty<QuotaWindow>(), "Test connection error - no quota available.", DateTimeOffset.UtcNow)
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
                _workspaceTabs!.SelectedIndex = 1;
                _activity.Start(_latestSnapshots, DateTimeOffset.UtcNow);
                RenderActivity();
                break;
            case 5:
                Require(_sessionSummary.Visible && _eventList.Items.Count > 0, "Session tracking and Events must be visible.");
                SaveSmokeImage(this, "TOKI_SMOKE_ACTIVITY_SCREENSHOT");
                VerifyDesktopFeatures();
                _workspaceTabs!.SelectedIndex = 2;
                break;
            case 6:
                SaveSmokeImage(this, "TOKI_SMOKE_PRIVACY_SCREENSHOT");
                _settings = _settings with { HideSensitiveInfo = false };
                ApplyPrivacy();
                _workspaceTabs!.SelectedIndex = 3;
                break;
            case 7:
                Require(!_remote.Running && !_shareTranscripts.Checked && _remoteToggle.Visible, "Remote sharing must start off with transcript sharing disabled.");
                SaveSmokeImage(this, "TOKI_SMOKE_REMOTE_SCREENSHOT");
                _remote.Start("loopback");
                break;
            case 8:
                Require(++_remoteSmokeWait < 50, "Packaged companion must become ready within 20 seconds.");
                if (_remote.Token is null || _remote.PairingCode is null) {
                    _smokeStep--;
                    break;
                }
                _remoteSmokeCheck = VerifyRemoteSmokeAsync();
                break;
            case 9:
                Require(++_remoteSmokeWait < 75, "Packaged companion protocol test must complete.");
                if (!_remoteSmokeCheck!.IsCompleted) {
                    _smokeStep--;
                    break;
                }
                _remoteSmokeCheck.GetAwaiter().GetResult();
                _remote.Stop();
                Require(!_remote.Running, "Stop sharing must stop the companion.");
                HideDashboard();
                _smokeTimer!.Stop();
                ExitApplication();
                break;
        }
    }

    private void VerifyDesktopFeatures() {
        _sessions = [
            new LocalSession(1, "claude", "Private launch plan", "fixture1.jsonl", @"C:\private-project", DateTimeOffset.UtcNow),
            new LocalSession(2, "codex", "Fix the parser", "fixture2.jsonl", @"C:\project-two", DateTimeOffset.UtcNow)
        ];
        RenderSessionList();
        _sessionSearch.Text = "PARSER";
        Require(_sessionList.Items.Count == 1 && _sessionList.Items[0].Text == "Codex", "Search must filter conversations case-insensitively.");
        _sessionProvider.SelectedIndex = 1;
        Require(_sessionList.Items.Count == 0, "Provider and query filters must combine.");
        _sessionProvider.SelectedIndex = 0;
        _settings = _settings with { HideSensitiveInfo = true };
        ApplyPrivacy();
        Require(_sessionSearch.Text == "" && !_sessionSearch.Enabled, "Privacy must clear and disable title searches.");
        Require(_sessionList.Items.Count == 2 && _sessionList.Items.Cast<ListViewItem>().All(i => i.SubItems[1].Text == "Conversation hidden"), "Privacy must mask every conversation title.");
        Require(!Descendants(this).Concat(Descendants(_flyout)).Any(c => c.Text.Contains("private@example.test")), "Private account details must not reach controls.");
        Require(_latestSnapshots.Single().Detail == "private@example.test", "Privacy must preserve the original provider data.");
        using var settings = new SettingsDialog(new AppSettings(ClaudeConfigDirectory: @"C:\private", HideSensitiveInfo: true), false);
        Require(Descendants(settings).OfType<TextBox>().All(t => t.UseSystemPasswordChar), "Private settings paths must be masked.");
    }

    private static void VerifyStartupRegistration() {
        var path = @"Software\Toki\Smoke-" + Guid.NewGuid().ToString("N");
        try {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(path);
            key.SetValue("Unrelated", "keep");
            LaunchAtLogin.SetRegistration(key, true, Application.ExecutablePath);
            Require((string?)key.GetValue(LaunchAtLogin.ValueName) == $"\"{Application.ExecutablePath}\" --background", "Startup must quote the executable path and launch quietly.");
            var rejected = false;
            try { LaunchAtLogin.SetRegistration(key, true, "relative.exe"); } catch (InvalidOperationException) { rejected = true; }
            Require(rejected && key.GetValue(LaunchAtLogin.ValueName) is string, "Invalid startup paths must preserve the existing registration.");
            LaunchAtLogin.SetRegistration(key, false, Application.ExecutablePath);
            Require(key.GetValue(LaunchAtLogin.ValueName) is null && (string?)key.GetValue("Unrelated") == "keep", "Removing startup must preserve other entries.");
        } finally {
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(path, throwOnMissingSubKey: false);
        }
    }

    private async Task VerifyRemoteSmokeAsync() {
        using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:8765"), Timeout = TimeSpan.FromSeconds(5) };
        client.DefaultRequestHeaders.Add("Origin", "http://127.0.0.1:8765");
        using var body = new StringContent(System.Text.Json.JsonSerializer.Serialize(new { code = _remote.PairingCode }), System.Text.Encoding.UTF8, "application/json");
        using var paired = await client.PostAsync("/api/pair?token=" + _remote.Token, body);
        paired.EnsureSuccessStatusCode();
        using var pairing = System.Text.Json.JsonDocument.Parse(await paired.Content.ReadAsStringAsync());
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", pairing.RootElement.GetProperty("token").GetString());
        _remote.Publish([new ProviderSnapshot("codex", "Codex", "", [new QuotaWindow("5h", 25, null)], null, DateTimeOffset.UtcNow)], [], false);
        for (var attempt = 0; attempt < 20; attempt++) {
            using var usage = System.Text.Json.JsonDocument.Parse(await client.GetStringAsync("/api/usage"));
            var accounts = usage.RootElement.GetProperty("accounts");
            if (accounts.GetArrayLength() > 0) {
                Require(accounts[0].GetProperty("windows")[0].GetProperty("left").GetDouble() == 75, "C# quota snapshots must use the phone's wire format.");
                using var send = await client.PostAsync("/api/send", new StringContent("{}"));
                Require(send.StatusCode == System.Net.HttpStatusCode.Forbidden, "Packaged companion must reject writes.");
                return;
            }
            await Task.Delay(50);
        }
        throw new InvalidOperationException("C# snapshots did not reach the packaged companion.");
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
