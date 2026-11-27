using System.ComponentModel;

namespace Toki.Windows;

internal sealed class QuotaBar : Control {
    private double _remainingPercent;

    internal QuotaBar() {
        AccessibleRole = AccessibleRole.ProgressBar;
        BackColor = Theme.Track;
        DoubleBuffered = true;
        Height = 10;
        ResizeRedraw = true;
        TabStop = false;
    }

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal double RemainingPercent {
        get => _remainingPercent;
        set {
            _remainingPercent = double.IsFinite(value) ? Math.Clamp(value, 0, 100) : 0;
            AccessibleDescription = $"{_remainingPercent:0.#}% remaining";
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        e.Graphics.Clear(Theme.Track);
        var width = (int)Math.Round(Width * (_remainingPercent / 100));
        if (width <= 0 || Height <= 0) {
            return;
        }

        using var brush = new SolidBrush(_remainingPercent <= 20 ? Theme.Amber : Theme.Sage);
        e.Graphics.FillRectangle(brush, 0, 0, width, Height);
    }
}
