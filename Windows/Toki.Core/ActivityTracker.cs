namespace Toki.Core;

public sealed record ActivityEvent(DateTimeOffset At, string Category, string Detail);

public sealed class ActivityTracker {
    private readonly Queue<ActivityEvent> _events = new();
    private readonly Dictionary<string, string?> _providerErrors = new();
    private Dictionary<(string, string), QuotaWindow> _baseline = new();
    private readonly HashSet<(string, string)> _resetWindows = new();
    private readonly Dictionary<(string, string), double> _lastUsage = new();
    public DateTimeOffset? StartedAt { get; private set; }
    public IReadOnlyList<ActivityEvent> Events => _events.Reverse().ToArray();

    public void Record(string category, string detail, DateTimeOffset now) {
        _events.Enqueue(new ActivityEvent(now, category, detail));
        while (_events.Count > 200) {
            _events.Dequeue();
        }
    }

    public void Observe(IReadOnlyList<ProviderSnapshot> snapshots, DateTimeOffset now) {
        foreach (var snapshot in snapshots) {
            if (StartedAt is not null && snapshot.Error is null) {
                foreach (var window in snapshot.Windows.Where(w => double.IsFinite(w.UsedPercent))) {
                    var key = (snapshot.Id, window.Label);
                    if (_lastUsage.TryGetValue(key, out var last) && window.UsedPercent < last) {
                        _resetWindows.Add(key);
                    }
                    _lastUsage[key] = window.UsedPercent;
                }
            }
            if (!_providerErrors.TryGetValue(snapshot.Id, out var previous) || previous != snapshot.Error) {
                if (snapshot.Error is not null || _providerErrors.ContainsKey(snapshot.Id)) {
                    Record("Provider", snapshot.Name + (snapshot.Error is null ? " recovered." : " is unavailable."), now);
                }
                _providerErrors[snapshot.Id] = snapshot.Error;
            }
        }
    }

    public void Start(IReadOnlyList<ProviderSnapshot> snapshots, DateTimeOffset now) {
        if (StartedAt is not null) {
            return;
        }
        _baseline = new();
        _resetWindows.Clear();
        _lastUsage.Clear();
        foreach (var snapshot in snapshots.Where(s => s.Error is null && now - s.CheckedAt <= TimeSpan.FromMinutes(2))) {
            foreach (var window in snapshot.Windows.Where(w => double.IsFinite(w.UsedPercent))) {
                _baseline[(snapshot.Id, window.Label)] = window;
                _lastUsage[(snapshot.Id, window.Label)] = window.UsedPercent;
            }
        }
        StartedAt = now;
        Record("Session", "Quota tracking started.", now);
    }

    public string Describe(IReadOnlyList<ProviderSnapshot> snapshots, DateTimeOffset now) {
        if (StartedAt is not { } start) {
            return "Start a session to track elapsed time and quota burn. Tracking lasts until Toki exits.";
        }
        var lines = new List<string> { $"Elapsed {Math.Max(0, (int)(now - start).TotalMinutes)} min" };
        foreach (var snapshot in snapshots) {
            foreach (var window in snapshot.Windows) {
                if (!_baseline.TryGetValue((snapshot.Id, window.Label), out var baseline)) {
                    continue;
                }
                var detail = "unavailable";
                if (snapshot.Error is null && now - snapshot.CheckedAt <= TimeSpan.FromMinutes(2) && double.IsFinite(window.UsedPercent)) {
                    detail = _resetWindows.Contains((snapshot.Id, window.Label)) || window.ResetsAt != baseline.ResetsAt || window.UsedPercent < baseline.UsedPercent
                        ? "window reset; burn unavailable"
                        : $"{window.UsedPercent - baseline.UsedPercent:0.#} percentage points used";
                }
                lines.Add($"{snapshot.Name} {window.Label}: {detail}");
            }
        }
        if (lines.Count == 1) {
            lines.Add("No comparable quota readings available.");
        }
        return string.Join(Environment.NewLine, lines);
    }

    public void Stop(IReadOnlyList<ProviderSnapshot> snapshots, DateTimeOffset now) {
        if (StartedAt is null) {
            return;
        }
        Record("Session", "Quota tracking ended. " + Describe(snapshots, now).Replace(Environment.NewLine, "; "), now);
        StartedAt = null;
        _baseline.Clear();
    }

    public void ClearEvents() => _events.Clear();
}
