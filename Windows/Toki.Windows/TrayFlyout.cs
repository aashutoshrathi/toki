using Toki.Core;

namespace Toki.Windows;

internal sealed class TrayFlyout : Form {
    private readonly FlowLayoutPanel _providers;
    private readonly Label _status;
    private readonly Button _refresh;
    private long _dismissedAt = long.MinValue;

    internal event Action? DashboardRequested;
    internal event Action? SettingsRequested;
    internal event Action? RefreshRequested;

    internal TrayFlyout(Icon icon) {
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9, FontStyle.Regular, GraphicsUnit.Point);
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        ClientSize = new Size(400, 490);
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        KeyPreview = true;
        Icon = icon;
        Text = "Toki usage";
        AccessibleName = "Toki compact usage panel";

        var root = new TableLayoutPanel {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 4
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 40));
        header.Controls.Add(Theme.CreateLabel("Toki", 19, Theme.Text, true), 0, 0);
        var dismiss = Theme.CreateButton("×");
        dismiss.MinimumSize = new Size(32, 28);
        dismiss.Padding = Padding.Empty;
        dismiss.AccessibleName = "Close usage panel";
        dismiss.Click += (_, _) => Hide();
        header.Controls.Add(dismiss, 1, 0);
        root.Controls.Add(header, 0, 0);
        _status = Theme.CreateLabel("Loading usage…", 9, Theme.MutedText);
        _status.Dock = DockStyle.Fill;
        _status.AutoSize = false;
        _status.AutoEllipsis = true;
        root.Controls.Add(_status, 0, 1);
        _providers = new FlowLayoutPanel {
            Dock = DockStyle.Fill,
            AutoScroll = true,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Margin = Padding.Empty
        };
        _providers.SizeChanged += (_, _) => FitProviderWidths();
        root.Controls.Add(_providers, 0, 2);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = Padding.Empty };
        _refresh = Theme.CreateButton("&Refresh", true);
        _refresh.Click += (_, _) => RefreshRequested?.Invoke();
        var dashboard = Theme.CreateButton("&Dashboard");
        dashboard.Click += (_, _) => { Hide(); DashboardRequested?.Invoke(); };
        var settings = Theme.CreateButton("&Settings");
        settings.Click += (_, _) => { Hide(); SettingsRequested?.Invoke(); };
        actions.Controls.AddRange(new Control[] { _refresh, dashboard, settings });
        root.Controls.Add(actions, 0, 3);
        Controls.Add(root);
    }

    internal void SetUsage(IReadOnlyList<ProviderSnapshot> snapshots, string status, bool refreshing) {
        _status.Text = status;
        _refresh.Enabled = !refreshing;
        _providers.SuspendLayout();
        foreach (var control in _providers.Controls.Cast<Control>().ToArray()) {
            control.Dispose();
        }
        _providers.Controls.Clear();
        foreach (var snapshot in snapshots) {
            var card = new Panel {
                BackColor = Theme.Card,
                Padding = new Padding(LogicalToDeviceUnits(10)),
                Margin = new Padding(0, 0, 0, LogicalToDeviceUnits(8))
            };
            var rows = new TableLayoutPanel {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 0,
                Margin = Padding.Empty
            };
            rows.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            AddRow(rows, Theme.CreateLabel(snapshot.Name, 11, Theme.Text, true), LogicalToDeviceUnits(26));
            if (snapshot.Error is not null) {
                var error = Theme.CreateLabel(snapshot.Error, 9, Theme.Error);
                error.AutoSize = false;
                error.AutoEllipsis = true;
                AddRow(rows, error, LogicalToDeviceUnits(76));
            } else if (snapshot.Windows.Count == 0) {
                AddRow(rows, Theme.CreateLabel("No quota reported", 9, Theme.MutedText), LogicalToDeviceUnits(26));
            } else {
                foreach (var window in snapshot.Windows) {
                    AddRow(rows, CreateQuotaRow(window), LogicalToDeviceUnits(54));
                }
            }
            card.Height = card.Padding.Vertical + rows.RowStyles.Cast<RowStyle>().Sum(style => (int)style.Height);
            card.Controls.Add(rows);
            _providers.Controls.Add(card);
        }
        FitProviderWidths();
        _providers.ResumeLayout(true);
    }

    private Control CreateQuotaRow(QuotaWindow window) {
        var row = new TableLayoutPanel { ColumnCount = 2, RowCount = 3, Margin = Padding.Empty };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        row.RowStyles.Add(new RowStyle(SizeType.Absolute, LogicalToDeviceUnits(22)));
        row.RowStyles.Add(new RowStyle(SizeType.Absolute, LogicalToDeviceUnits(8)));
        row.RowStyles.Add(new RowStyle(SizeType.Absolute, LogicalToDeviceUnits(24)));
        row.Controls.Add(Theme.CreateLabel(window.Label, 9.5f, Theme.Text, true), 0, 0);
        var remaining = window.RemainingPercent;
        row.Controls.Add(Theme.CreateLabel($"{remaining:0.#}% left", 9.5f, remaining <= 20 ? Theme.Amber : Theme.Sage, true), 1, 0);
        var bar = new QuotaBar {
            Dock = DockStyle.Fill,
            RemainingPercent = remaining,
            Margin = new Padding(3, 1, 3, 1),
            AccessibleName = $"{window.Label} remaining quota"
        };
        row.Controls.Add(bar, 0, 1);
        row.SetColumnSpan(bar, 2);
        var reset = window.ResetsAt is { } date ? $"Resets {date.ToLocalTime():MMM d, h:mm tt}" : "Reset time unavailable";
        var resetLabel = Theme.CreateLabel(reset, 8.5f, Theme.MutedText);
        resetLabel.Dock = DockStyle.Fill;
        row.Controls.Add(resetLabel, 0, 2);
        row.SetColumnSpan(resetLabel, 2);
        return row;
    }

    internal void ToggleFromTray(Point anchor) {
        if (Visible) {
            Hide();
            return;
        }
        // Clicking the tray can deactivate this window before NotifyIcon reports the click.
        if (_dismissedAt != long.MinValue && Environment.TickCount64 - _dismissedAt < 200) {
            return;
        }
        ShowAt(anchor);
    }

    internal void ShowAt(Point? anchor) {
        var screen = Screen.FromPoint(anchor ?? Cursor.Position);
        var area = screen.WorkingArea;
        Location = new Point(area.Right - Math.Min(Width, area.Width), area.Bottom - Math.Min(Height, area.Height));
        Show();
        var size = new Size(Math.Min(LogicalToDeviceUnits(400), area.Width), Math.Min(LogicalToDeviceUnits(490), area.Height));
        var point = anchor ?? new Point(area.Right, area.Bottom);
        Bounds = FlyoutPlacement.Place(area, size, point, LogicalToDeviceUnits(8));
        FitProviderWidths();
        Activate();
    }

    protected override void OnDeactivate(EventArgs e) {
        base.OnDeactivate(e);
        _dismissedAt = Environment.TickCount64;
        Hide();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (keyData == Keys.Escape) {
            Hide();
            return true;
        }
        if (keyData == Keys.F5) {
            if (_refresh.Enabled) {
                RefreshRequested?.Invoke();
            }
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (e.CloseReason == CloseReason.UserClosing) {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using var pen = new Pen(Theme.Track);
        e.Graphics.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
    }

    private void FitProviderWidths() {
        var width = Math.Max(1, _providers.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
        foreach (Control card in _providers.Controls) {
            card.Width = width;
        }
    }

    private static void AddRow(TableLayoutPanel panel, Control control, int height) {
        var row = panel.RowCount++;
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        control.Dock = DockStyle.Fill;
        panel.Controls.Add(control, 0, row);
    }
}
