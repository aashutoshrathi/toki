using Toki.Core;

namespace Toki.Windows;

internal sealed class MainForm : Form {
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan NotificationCooldown = TimeSpan.FromMinutes(90);

    private readonly bool _smokeTest;
    private readonly EventWaitHandle _showSignal;
    private RegisteredWaitHandle? _showRegistration;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly Dictionary<string, DateTimeOffset> _notificationHistory = new(StringComparer.OrdinalIgnoreCase);
    private readonly Icon _brandIcon;
    private readonly Image _brandImage;
    private readonly NotifyIcon _trayIcon;
    private readonly ContextMenuStrip _trayMenu;
    private readonly ToolStripMenuItem _showMenuItem;
    private readonly ToolStripMenuItem _refreshMenuItem;
    private readonly ToolStripMenuItem _doNotDisturbMenuItem;
    private readonly System.Windows.Forms.Timer _refreshTimer;
    private readonly TableLayoutPanel _cardsPanel;
    private readonly Label _statusLabel;
    private readonly Label _lastCheckedLabel;
    private readonly Button _refreshButton;
    private readonly Button _settingsButton;
    private System.Windows.Forms.Timer? _smokeTimer;
    private AppSettings _settings;
    private bool _settingsLoadFailed;
    private bool _exitRequested;
    private Task _activeRefresh = Task.CompletedTask;

    internal MainForm(bool smokeTest, EventWaitHandle showSignal) {
        _smokeTest = smokeTest;
        _showSignal = showSignal;
        _settings = new AppSettings();
        if (!smokeTest) {
            try {
                _settings = SettingsStore.Load();
            } catch (Exception) {
                _settingsLoadFailed = true;
            }
        }

        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Theme.Background;
        ClientSize = new Size(960, 720);
        Font = new Font("Segoe UI", 9, FontStyle.Regular, GraphicsUnit.Point);
        ForeColor = Theme.Text;
        KeyPreview = true;
        MinimumSize = new Size(760, 600);
        Name = "TokiMainForm";
        StartPosition = FormStartPosition.CenterScreen;
        Text = "Toki - Windows Preview 4.0.0-preview.1";

        _brandIcon = BrandIcon.Load();
        _brandImage = _brandIcon.ToBitmap();
        Icon = _brandIcon;

        var root = new TableLayoutPanel {
            BackColor = Theme.Background,
            ColumnCount = 1,
            Dock = DockStyle.Fill,
            Padding = new Padding(24),
            RowCount = 4
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var header = new TableLayoutPanel {
            BackColor = Theme.Background,
            ColumnCount = 3,
            Dock = DockStyle.Fill,
            RowCount = 1
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 58));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var logo = new PictureBox {
            BackColor = Theme.Background,
            Dock = DockStyle.Fill,
            Image = _brandImage,
            Margin = new Padding(0, 4, 8, 4),
            Name = "TokiBrandLogo",
            SizeMode = PictureBoxSizeMode.Zoom
        };
        header.Controls.Add(logo, 0, 0);

        var titlePanel = new FlowLayoutPanel {
            AutoSize = true,
            BackColor = Theme.Background,
            FlowDirection = FlowDirection.TopDown,
            Margin = new Padding(0),
            WrapContents = false
        };
        var title = Theme.CreateLabel("Toki", 22, Theme.Text, true);
        title.Margin = new Padding(0);
        var subtitle = Theme.CreateLabel("Windows preview 4.0.0-preview.1", 9, Theme.MutedText);
        subtitle.Margin = new Padding(0);
        titlePanel.Controls.Add(title);
        titlePanel.Controls.Add(subtitle);
        header.Controls.Add(titlePanel, 1, 0);

        var headerButtons = new FlowLayoutPanel {
            AutoSize = true,
            BackColor = Theme.Background,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false
        };
        _settingsButton = Theme.CreateButton("Settings");
        _settingsButton.Name = "SettingsButton";
        _settingsButton.Click += SettingsButton_Click;
        _refreshButton = Theme.CreateButton("Refresh", true);
        _refreshButton.Name = "RefreshButton";
        _refreshButton.Click += async (_, _) => await RefreshUsageAsync();
        headerButtons.Controls.Add(_settingsButton);
        headerButtons.Controls.Add(_refreshButton);
        header.Controls.Add(headerButtons, 2, 0);
        root.Controls.Add(header, 0, 0);

        var previewNote = Theme.CreateLabel("Preview scope: Claude Code and Codex usage only. No agent control, remote access, or automatic updates.", 9, Theme.MutedText);
        previewNote.Dock = DockStyle.Fill;
        previewNote.TextAlign = ContentAlignment.MiddleLeft;
        root.Controls.Add(previewNote, 0, 1);

        var statusPanel = new TableLayoutPanel {
            BackColor = Theme.Background,
            ColumnCount = 2,
            Dock = DockStyle.Fill,
            RowCount = 1
        };
        statusPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 65));
        statusPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 35));
        _statusLabel = Theme.CreateLabel(smokeTest ? "Smoke test initialized." : "Usage has not been loaded.", 9.5f, Theme.MutedText);
        _statusLabel.AutoEllipsis = true;
        _statusLabel.AutoSize = false;
        _statusLabel.Dock = DockStyle.Fill;
        _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
        statusPanel.Controls.Add(_statusLabel, 0, 0);
        _lastCheckedLabel = Theme.CreateLabel("Last checked: never", 9, Theme.MutedText);
        _lastCheckedLabel.AutoEllipsis = true;
        _lastCheckedLabel.AutoSize = false;
        _lastCheckedLabel.Dock = DockStyle.Fill;
        _lastCheckedLabel.TextAlign = ContentAlignment.MiddleRight;
        statusPanel.Controls.Add(_lastCheckedLabel, 1, 0);
        root.Controls.Add(statusPanel, 0, 2);

        _cardsPanel = new TableLayoutPanel {
            AutoScroll = true,
            BackColor = Theme.Background,
            ColumnCount = 2,
            Dock = DockStyle.Fill,
            Name = "ProviderCardsPanel",
            RowCount = 0
        };
        _cardsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        _cardsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        root.Controls.Add(_cardsPanel, 0, 3);
        Controls.Add(root);

        if (smokeTest) {
            RenderSnapshots(new[] {
                new ProviderSnapshot("claude-code", "Claude Code", "Smoke test fixture", new[] {
                    new QuotaWindow("5h", 25, DateTimeOffset.UtcNow.AddHours(2)),
                    new QuotaWindow("7d", 80, DateTimeOffset.UtcNow.AddDays(3))
                }, null, DateTimeOffset.UtcNow),
                new ProviderSnapshot("codex", "Codex", "Smoke test fixture", Array.Empty<QuotaWindow>(),
                    "Offline test: sign in to see quota.", DateTimeOffset.UtcNow)
            });
        } else {
            AddFullWidthMessage("Loading provider usage...", Theme.MutedText);
        }

        _showMenuItem = new ToolStripMenuItem("Show dashboard");
        _showMenuItem.Click += (_, _) => ToggleDashboard();
        _refreshMenuItem = new ToolStripMenuItem("Refresh usage");
        _refreshMenuItem.Click += async (_, _) => await RefreshUsageAsync();
        _doNotDisturbMenuItem = new ToolStripMenuItem("Do not disturb") {
            CheckOnClick = false,
            Checked = _settings.DoNotDisturb
        };
        _doNotDisturbMenuItem.Click += DoNotDisturbMenuItem_Click;
        var quitMenuItem = new ToolStripMenuItem("Quit Toki");
        quitMenuItem.Click += (_, _) => ExitApplication();

        _trayMenu = new ContextMenuStrip();
        _trayMenu.Items.Add(_showMenuItem);
        _trayMenu.Items.Add(_refreshMenuItem);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(_doNotDisturbMenuItem);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(quitMenuItem);

        _trayIcon = new NotifyIcon {
            BalloonTipTitle = "Toki",
            ContextMenuStrip = _trayMenu,
            Icon = _brandIcon,
            Text = "Toki - Windows Preview",
            Visible = true
        };
        _trayIcon.BalloonTipClicked += (_, _) => ShowDashboard();
        _trayIcon.MouseClick += (_, e) => {
            if (e.Button == MouseButtons.Left) {
                ShowDashboard();
            }
        };

        _refreshTimer = new System.Windows.Forms.Timer {
            Interval = (int)RefreshInterval.TotalMilliseconds
        };
        _refreshTimer.Tick += async (_, _) => await RefreshUsageAsync();

        VisibleChanged += (_, _) => UpdateShowMenuText();
        Resize += (_, _) => UpdateShowMenuText();
        KeyDown += MainForm_KeyDown;
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        if (_smokeTest) {
            _smokeTimer = new System.Windows.Forms.Timer { Interval = 300 };
            _smokeTimer.Tick += (_, _) => {
                _smokeTimer.Stop();
                var screenshotPath = Environment.GetEnvironmentVariable("TOKI_SMOKE_SCREENSHOT");
                if (!string.IsNullOrWhiteSpace(screenshotPath)) {
                    using var bitmap = new Bitmap(Width, Height);
                    DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
                    bitmap.Save(screenshotPath, System.Drawing.Imaging.ImageFormat.Png);
                }
                ExitApplication();
            };
            _smokeTimer.Start();
            return;
        }

        _showRegistration = ThreadPool.RegisterWaitForSingleObject(_showSignal, (_, _) => {
            try {
                if (!IsDisposed && IsHandleCreated) {
                    BeginInvoke((Action)ShowDashboard);
                }
            } catch (InvalidOperationException) {
            }
        }, null, Timeout.Infinite, false);

        if (_settingsLoadFailed) {
            MessageBox.Show(
                this,
                "Toki could not read its settings. Default settings are in use, and the existing file was not changed.",
                "Toki Settings",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }

        _refreshTimer.Start();
        _ = RefreshUsageAsync();
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (_exitRequested && !_activeRefresh.IsCompleted && e.CloseReason == CloseReason.UserClosing) {
            e.Cancel = true;
            return;
        }
        if (!_exitRequested && e.CloseReason == CloseReason.UserClosing) {
            e.Cancel = true;
            HideDashboard();
            return;
        }

        _lifetime.Cancel();
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            _showRegistration?.Unregister(null);
            _refreshTimer.Dispose();
            _smokeTimer?.Dispose();
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayMenu.Dispose();
            _brandImage.Dispose();
            _brandIcon.Dispose();
        }
        base.Dispose(disposing);
    }

    private Task RefreshUsageAsync() {
        if (!_activeRefresh.IsCompleted) {
            return _activeRefresh;
        }
        _activeRefresh = RunRefreshAsync();
        return _activeRefresh;
    }

    private async Task RunRefreshAsync() {
        if (_smokeTest || _exitRequested || IsDisposed || Disposing) {
            return;
        }
        if (!await _refreshGate.WaitAsync(0)) {
            return;
        }

        var settings = _settings;
        try {
            SetRefreshing(true);
            var refreshStarted = DateTimeOffset.UtcNow;
            var snapshots = await Task.Run(
                () => UsageReader.RefreshAsync(settings, _lifetime.Token),
                _lifetime.Token);
            if (!CanApplyRefreshResults() || settings != _settings) {
                return;
            }

            RenderSnapshots(snapshots);
            _statusLabel.ForeColor = Theme.MutedText;
            var failures = snapshots.Count(snapshot => snapshot.Error is not null);
            if (snapshots.Count == 0) {
                _statusLabel.Text = "No provider usage is available.";
            } else {
                _statusLabel.Text = failures > 0
                    ? $"{failures} provider(s) unavailable. Check the account cards."
                    : "Usage is current.";
            }
            _lastCheckedLabel.Text = $"Last checked: {DateTimeOffset.Now:g}";
            UpdateTrayTooltip(snapshots);
            DeliverLowQuotaNotifications(snapshots, refreshStarted);
        } catch (OperationCanceledException) when (_exitRequested || _lifetime.IsCancellationRequested) {
        } catch (Exception) {
            if (!CanApplyRefreshResults() || settings != _settings) {
                return;
            }

            ClearCards();
            AddFullWidthMessage("Usage refresh failed. No previous quota values are shown.", Theme.Error);
            _statusLabel.ForeColor = Theme.Error;
            _statusLabel.Text = "Refresh failed. Check provider sign-in and try again.";
            _lastCheckedLabel.Text = $"Refresh failed: {DateTimeOffset.Now:g}";
            _trayIcon.Text = "Toki - Usage unavailable";
        } finally {
            if (!IsDisposed && !Disposing) {
                SetRefreshing(false);
            }
            _refreshGate.Release();
            if (settings != _settings && CanApplyRefreshResults()) {
                BeginInvoke((Action)(() => _ = RefreshUsageAsync()));
            }
        }
    }

    private bool CanApplyRefreshResults() {
        return !_exitRequested && !_lifetime.IsCancellationRequested && !IsDisposed && !Disposing;
    }

    private void SetRefreshing(bool refreshing) {
        _refreshButton.Enabled = !refreshing;
        _refreshMenuItem.Enabled = !refreshing;
        _refreshButton.Text = refreshing ? "Refreshing..." : "Refresh";
        if (refreshing) {
            _statusLabel.ForeColor = Theme.MutedText;
            _statusLabel.Text = "Refreshing provider usage...";
        }
    }

    private void RenderSnapshots(IReadOnlyList<ProviderSnapshot> snapshots) {
        ClearCards();
        if (snapshots.Count == 0) {
            AddFullWidthMessage("No provider usage is available. Check your sign-in and Settings.", Theme.MutedText);
            return;
        }

        _cardsPanel.SuspendLayout();
        _cardsPanel.RowCount = (snapshots.Count + 1) / 2;
        for (var row = 0; row < _cardsPanel.RowCount; row++) {
            _cardsPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, LogicalToDeviceUnits(326)));
        }
        for (var index = 0; index < snapshots.Count; index++) {
            var card = new ProviderCard(snapshots[index]) {
                Dock = DockStyle.Fill
            };
            _cardsPanel.Controls.Add(card, index % 2, index / 2);
        }
        _cardsPanel.ResumeLayout();
    }

    private void ClearCards() {
        _cardsPanel.SuspendLayout();
        var controls = _cardsPanel.Controls.Cast<Control>().ToArray();
        foreach (var control in controls) {
            control.Dispose();
        }
        _cardsPanel.Controls.Clear();
        _cardsPanel.RowStyles.Clear();
        _cardsPanel.RowCount = 0;
        _cardsPanel.ResumeLayout();
    }

    private void AddFullWidthMessage(string message, Color color) {
        var label = Theme.CreateLabel(message, 11, color);
        label.AutoSize = false;
        label.Dock = DockStyle.Fill;
        label.Margin = new Padding(8);
        label.TextAlign = ContentAlignment.MiddleCenter;
        _cardsPanel.RowCount = 1;
        _cardsPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _cardsPanel.Controls.Add(label, 0, 0);
        _cardsPanel.SetColumnSpan(label, 2);
    }

    private void UpdateTrayTooltip(IReadOnlyList<ProviderSnapshot> snapshots) {
        if (snapshots.Count == 0) {
            _trayIcon.Text = "Toki - No provider usage";
            return;
        }

        var summaries = new List<string>();
        foreach (var snapshot in snapshots) {
            if (!string.IsNullOrWhiteSpace(snapshot.Error)) {
                summaries.Add($"{snapshot.Name}: error");
                continue;
            }

            var validWindows = snapshot.Windows
                .Where(window => double.IsFinite(window.UsedPercent))
                .OrderBy(window => window.RemainingPercent)
                .ToArray();
            summaries.Add(validWindows.Length == 0
                ? $"{snapshot.Name}: no data"
                : $"{snapshot.Name} {validWindows[0].Label} {validWindows[0].RemainingPercent:0.#}%");
        }

        var text = $"Toki - {string.Join(" | ", summaries)}";
        _trayIcon.Text = text.Length <= 127 ? text : $"{text[..124]}...";
    }

    private void DeliverLowQuotaNotifications(IReadOnlyList<ProviderSnapshot> snapshots, DateTimeOffset refreshStarted) {
        if (!_settings.NotificationsEnabled || _settings.DoNotDisturb) {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var messages = new List<string>();
        var notificationKeys = new List<string>();
        foreach (var snapshot in snapshots) {
            if (!string.IsNullOrWhiteSpace(snapshot.Error)
                || snapshot.CheckedAt < refreshStarted.AddSeconds(-5)
                || snapshot.CheckedAt > now.AddMinutes(1)
                || now - snapshot.CheckedAt > TimeSpan.FromMinutes(2)) {
                continue;
            }

            foreach (var window in snapshot.Windows) {
                if (!double.IsFinite(window.UsedPercent)) {
                    continue;
                }

                var remaining = window.RemainingPercent;
                if (remaining > 20) {
                    continue;
                }

                var key = $"{snapshot.Id}:{window.Label}";
                if (_notificationHistory.TryGetValue(key, out var lastSent)
                    && now - lastSent < NotificationCooldown) {
                    continue;
                }

                notificationKeys.Add(key);
                messages.Add($"{snapshot.Name} {window.Label}: {remaining:0.#}% left");
            }
        }

        if (messages.Count == 0) {
            return;
        }

        var text = string.Join("; ", messages);
        if (text.Length > 240) {
            text = $"{text[..237]}...";
        }
        _trayIcon.ShowBalloonTip(8000, "Toki quota low", text, ToolTipIcon.Warning);
        foreach (var key in notificationKeys) {
            _notificationHistory[key] = now;
        }
    }

    private async void SettingsButton_Click(object? sender, EventArgs e) {
        using var dialog = new SettingsDialog(_settings);
        if (dialog.ShowDialog(this) != DialogResult.OK || dialog.Settings is not { } settings) {
            return;
        }
        if (!TrySaveSettings(settings)) {
            return;
        }

        await RefreshUsageAsync();
    }

    private void DoNotDisturbMenuItem_Click(object? sender, EventArgs e) {
        var settings = _settings with { DoNotDisturb = !_settings.DoNotDisturb };
        TrySaveSettings(settings);
    }

    private bool TrySaveSettings(AppSettings settings) {
        if (_settingsLoadFailed) {
            var result = MessageBox.Show(
                this,
                "The existing settings file could not be read. Replace it with these settings?",
                "Toki Settings",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (result != DialogResult.Yes) {
                return false;
            }
        }

        try {
            SettingsStore.Save(settings);
        } catch (Exception) {
            MessageBox.Show(
                this,
                "Toki could not save settings. Your previous settings were kept where possible. Check file permissions and available disk space.",
                "Toki Settings",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return false;
        }

        _settings = settings;
        _settingsLoadFailed = false;
        _doNotDisturbMenuItem.Checked = settings.DoNotDisturb;
        return true;
    }

    private void MainForm_KeyDown(object? sender, KeyEventArgs e) {
        if (e.KeyCode == Keys.F5) {
            e.Handled = true;
            _ = RefreshUsageAsync();
        } else if (e.Control && e.KeyCode == Keys.Oemcomma) {
            e.Handled = true;
            SettingsButton_Click(this, EventArgs.Empty);
        }
    }

    private void ToggleDashboard() {
        if (Visible && WindowState != FormWindowState.Minimized) {
            HideDashboard();
        } else {
            ShowDashboard();
        }
    }

    private void ShowDashboard() {
        if (IsDisposed || Disposing || _exitRequested) {
            return;
        }

        Show();
        if (WindowState == FormWindowState.Minimized) {
            WindowState = FormWindowState.Normal;
        }
        Activate();
        UpdateShowMenuText();
    }

    private void HideDashboard() {
        Hide();
        UpdateShowMenuText();
    }

    private void UpdateShowMenuText() {
        _showMenuItem.Text = Visible && WindowState != FormWindowState.Minimized ? "Hide dashboard" : "Show dashboard";
    }

    private async void ExitApplication() {
        if (_exitRequested) {
            return;
        }

        _exitRequested = true;
        Enabled = false;
        _refreshTimer.Stop();
        _smokeTimer?.Stop();
        _lifetime.Cancel();
        _trayIcon.Visible = false;
        await _activeRefresh;
        Close();
    }
}
