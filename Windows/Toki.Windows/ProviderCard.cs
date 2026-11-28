using Toki.Core;

namespace Toki.Windows;

internal sealed class ProviderCard : UserControl {
    internal ProviderCard(ProviderSnapshot snapshot) {
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        AccessibleName = $"{snapshot.Name} usage";
        BackColor = Theme.Card;
        Height = 310;
        Margin = new Padding(8);
        MinimumSize = new Size(300, 280);
        Name = $"{snapshot.Id}ProviderCard";
        Padding = new Padding(18);

        var layout = new TableLayoutPanel {
            BackColor = Theme.Card,
            ColumnCount = 1,
            Dock = DockStyle.Fill,
            RowCount = 4
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));

        var nameLabel = Theme.CreateLabel(snapshot.Name, 15, Theme.Text, true);
        nameLabel.Dock = DockStyle.Fill;
        nameLabel.TextAlign = ContentAlignment.MiddleLeft;
        layout.Controls.Add(nameLabel, 0, 0);

        var detailLabel = Theme.CreateLabel(snapshot.Detail, 9, Theme.MutedText);
        detailLabel.AutoEllipsis = true;
        detailLabel.AutoSize = false;
        detailLabel.Dock = DockStyle.Fill;
        detailLabel.TextAlign = ContentAlignment.MiddleLeft;
        layout.Controls.Add(detailLabel, 0, 1);

        var content = new Panel {
            BackColor = Theme.Card,
            Dock = DockStyle.Fill
        };
        if (!string.IsNullOrWhiteSpace(snapshot.Error)) {
            content.Controls.Add(new Label {
                AutoSize = false,
                Dock = DockStyle.Fill,
                Font = new Font("Segoe UI", 10, FontStyle.Regular, GraphicsUnit.Point),
                ForeColor = Theme.Error,
                Text = $"Usage unavailable\n\n{snapshot.Error}",
                TextAlign = ContentAlignment.MiddleLeft
            });
        } else {
            content.Controls.Add(CreateWindowsPanel(snapshot.Windows));
        }
        layout.Controls.Add(content, 0, 2);

        var checkedLabel = Theme.CreateLabel($"Checked {snapshot.CheckedAt.ToLocalTime():g}", 8.5f, Theme.MutedText);
        checkedLabel.Dock = DockStyle.Fill;
        checkedLabel.TextAlign = ContentAlignment.MiddleLeft;
        layout.Controls.Add(checkedLabel, 0, 3);

        Controls.Add(layout);
    }

    private static Control CreateWindowsPanel(IReadOnlyList<QuotaWindow> windows) {
        if (windows.Count == 0) {
            return new Label {
                AutoSize = false,
                Dock = DockStyle.Fill,
                Font = new Font("Segoe UI", 10, FontStyle.Regular, GraphicsUnit.Point),
                ForeColor = Theme.MutedText,
                Text = "No usage windows were reported.",
                TextAlign = ContentAlignment.MiddleLeft
            };
        }

        var panel = new TableLayoutPanel {
            AutoScroll = true,
            BackColor = Theme.Card,
            ColumnCount = 1,
            Dock = DockStyle.Fill,
            Margin = new Padding(0),
            RowCount = windows.Count
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        for (var index = 0; index < windows.Count; index++) {
            var window = windows[index];
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
            if (!double.IsFinite(window.UsedPercent)) {
                panel.Controls.Add(new Label {
                    AutoSize = false,
                    Dock = DockStyle.Fill,
                    Font = new Font("Segoe UI", 9.5f, FontStyle.Regular, GraphicsUnit.Point),
                    ForeColor = Theme.Error,
                    Text = $"{window.Label}: invalid usage data",
                    TextAlign = ContentAlignment.MiddleLeft
                }, 0, index);
                continue;
            }

            panel.Controls.Add(new QuotaWindowView(window) { Dock = DockStyle.Top }, 0, index);
        }

        return panel;
    }
}

internal sealed class QuotaWindowView : UserControl {
    internal QuotaWindowView(QuotaWindow window) {
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Theme.Card;
        Height = 78;
        Margin = new Padding(0, 0, 0, 4);
        Padding = new Padding(0, 4, 0, 0);

        var remaining = window.RemainingPercent;
        var label = string.IsNullOrWhiteSpace(window.Label) ? "Usage window" : window.Label;

        var layout = new TableLayoutPanel {
            BackColor = Theme.Card,
            ColumnCount = 2,
            Dock = DockStyle.Fill,
            RowCount = 3
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 14));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var windowLabel = Theme.CreateLabel(label, 10, Theme.Text, true);
        windowLabel.Dock = DockStyle.Fill;
        windowLabel.TextAlign = ContentAlignment.MiddleLeft;
        layout.Controls.Add(windowLabel, 0, 0);

        var remainingLabel = Theme.CreateLabel($"{remaining:0.#}% remaining", 10, remaining <= 20 ? Theme.Amber : Theme.Sage, true);
        remainingLabel.Dock = DockStyle.Fill;
        remainingLabel.TextAlign = ContentAlignment.MiddleRight;
        layout.Controls.Add(remainingLabel, 1, 0);

        var bar = new QuotaBar {
            AccessibleName = $"{label} remaining quota",
            Dock = DockStyle.Fill,
            RemainingPercent = remaining
        };
        layout.Controls.Add(bar, 0, 1);
        layout.SetColumnSpan(bar, 2);

        var resetText = window.ResetsAt is { } resetsAt
            ? $"Resets {resetsAt.ToLocalTime():ddd, MMM d, h:mm tt} (local)"
            : "Reset time unavailable";
        var resetLabel = Theme.CreateLabel(resetText, 8.5f, Theme.MutedText);
        resetLabel.Dock = DockStyle.Fill;
        resetLabel.TextAlign = ContentAlignment.MiddleLeft;
        layout.Controls.Add(resetLabel, 0, 2);
        layout.SetColumnSpan(resetLabel, 2);

        Controls.Add(layout);
    }
}
