using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json;
using Toki.Core;

namespace Toki.Windows;

internal sealed partial class MainForm {
    private readonly ActivityTracker _activity = new();
    private readonly RemoteCompanion _remote = new();
    private readonly System.Windows.Forms.Timer _workspaceTimer = new() { Interval = 15000 };
    private Task _activeScan = Task.CompletedTask;
    private IReadOnlyList<LocalSession> _sessions = [];
    private readonly Label _sessionSummary = new();
    private readonly ListBox _eventList = new();
    private readonly ListView _sessionList = new();
    private readonly Label _scanStatus = new();
    private readonly TextBox _sessionSearch = new() { PlaceholderText = "Search conversation or project", Width = 340, Name = "SessionSearch" };
    private readonly ComboBox _sessionProvider = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 140, Name = "SessionProviderFilter" };
    private bool _scanIncomplete;
    private readonly ComboBox _reach = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _addresses = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _shareTranscripts = new() { Text = "Share recent conversation transcripts with paired devices", AutoSize = true };
    private readonly Button _remoteToggle = Theme.CreateButton("Start sharing", true);
    private readonly TextBox _connectLink = new() { ReadOnly = true };
    private readonly Label _remoteStatus = new();
    private readonly ListBox _devices = new();
    private readonly List<string> _deviceIds = new();
    private TabControl? _workspaceTabs;

    private TabControl CreateWorkspace() {
        var tabs = new TabControl { Dock = DockStyle.Fill, Name = "WorkspaceTabs" };
        _workspaceTabs = tabs;
        TabPage Page(string name) {
            var page = new TabPage(name) { BackColor = Theme.Background, ForeColor = Theme.Text, Padding = new Padding(10) };
            tabs.TabPages.Add(page);
            return page;
        }
        Page("Usage").Controls.Add(_cardsPanel);
        var activity = Page("Session & Events");
        var layout = VerticalLayout(58, 125, -1);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true };
        var start = Theme.CreateButton("Start session");
        var stop = Theme.CreateButton("End session");
        var clear = Theme.CreateButton("Clear events");
        start.Click += (_, _) => { _activity.Start(_latestSnapshots, DateTimeOffset.UtcNow); RenderActivity(); };
        stop.Click += (_, _) => { _activity.Stop(_latestSnapshots, DateTimeOffset.UtcNow); RenderActivity(); };
        clear.Click += (_, _) => { _activity.ClearEvents(); RenderActivity(); };
        buttons.Controls.AddRange([start, stop, clear]);
        layout.Controls.Add(buttons, 0, 0);
        _sessionSummary.Dock = DockStyle.Fill;
        _sessionSummary.AutoEllipsis = true;
        layout.Controls.Add(_sessionSummary, 0, 1);
        ConfigureList(_eventList);
        _eventList.HorizontalScrollbar = true;
        layout.Controls.Add(_eventList, 0, 2);
        activity.Controls.Add(layout);
        var sessions = Page("Recent sessions");
        var sessionLayout = VerticalLayout(42, 62, -1);
        var filters = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        _sessionSearch.BackColor = Theme.Card;
        _sessionSearch.ForeColor = Theme.Text;
        _sessionSearch.AccessibleName = "Search recent conversations";
        _sessionSearch.Enabled = !_settings.HideSensitiveInfo;
        _sessionProvider.AccessibleName = "Filter by provider";
        _sessionProvider.Items.AddRange(["All providers", "Claude Code", "Codex"]);
        _sessionProvider.SelectedIndex = 0;
        _sessionSearch.TextChanged += (_, _) => RenderSessionList();
        _sessionProvider.SelectedIndexChanged += (_, _) => RenderSessionList();
        filters.Controls.AddRange([_sessionSearch, _sessionProvider]);
        sessionLayout.Controls.Add(filters, 0, 0);
        _scanStatus.Dock = DockStyle.Fill;
        _scanStatus.Text = "Recent local conversations, not a list of live agents. Refreshes every 15 seconds.";
        sessionLayout.Controls.Add(_scanStatus, 0, 1);
        _sessionList.Dock = DockStyle.Fill;
        _sessionList.View = View.Details;
        _sessionList.FullRowSelect = true;
        _sessionList.BackColor = Theme.Card;
        _sessionList.ForeColor = Theme.Text;
        _sessionList.Columns.Add("Provider", 100);
        _sessionList.Columns.Add("Conversation", 400);
        _sessionList.Columns.Add("Last written", 180);
        sessionLayout.Controls.Add(_sessionList, 0, 2);
        sessions.Controls.Add(sessionLayout);
        Page("Remote viewing").Controls.Add(CreateRemotePanel());
        _workspaceTimer.Tick += async (_, _) => {
            RenderActivity();
            await ScanSessionsAsync();
            PublishRemote();
            RenderRemote();
        };
        _remote.Output += _ => DispatchRemote(RenderRemote);
        _remote.Stopped += () => DispatchRemote(() => {
            _activity.Record("Remote", "Remote viewing stopped. Start again to create a new connection.", DateTimeOffset.UtcNow);
            RenderActivity();
            RenderRemote();
        });
        RenderActivity();
        return tabs;
    }

    private static TableLayoutPanel VerticalLayout(params int[] heights) {
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = heights.Length };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var height in heights) {
            layout.RowStyles.Add(height < 0 ? new RowStyle(SizeType.Percent, 100) : new RowStyle(SizeType.Absolute, height));
        }
        return layout;
    }

    private static void ConfigureList(ListBox list) {
        list.Dock = DockStyle.Fill;
        list.BackColor = Theme.Card;
        list.ForeColor = Theme.Text;
        list.BorderStyle = BorderStyle.None;
        list.IntegralHeight = false;
    }

    private Control CreateRemotePanel() {
        var layout = VerticalLayout(70, 44, 40, 44, 42, 44, -1, 44);
        var note = Theme.CreateLabel("Share quotas with your phone using a link and a rotating six-digit code. Transcript sharing is optional and includes prompts and tool output. Sharing stays off after restart. No replies or terminal control.", 9.5f, Theme.MutedText);
        note.AutoSize = false;
        note.Dock = DockStyle.Fill;
        layout.Controls.Add(note, 0, 0);
        var options = new FlowLayoutPanel { Dock = DockStyle.Fill };
        _reach.Items.AddRange(["This computer", "Local network", "Tailscale"]);
        _reach.SelectedIndex = 0;
        _reach.Width = 160;
        _addresses.Width = 200;
        _reach.SelectedIndexChanged += (_, _) => RefreshAddresses();
        _addresses.SelectedIndexChanged += (_, _) => RenderRemote();
        _remoteToggle.Click += async (_, _) => {
            if (_remote.Running) {
                _remote.Stop();
                _activity.Record("Remote", "Remote viewing stopped; paired sessions expired.", DateTimeOffset.UtcNow);
            } else {
                try {
                    await ScanSessionsAsync();
                    _remote.Start(AccessPolicy());
                    PublishRemote();
                    _activity.Record("Remote", "Read-only remote viewing started.", DateTimeOffset.UtcNow);
                } catch (Exception) {
                    MessageBox.Show(this, "Remote viewing could not start. Use the packaged build, check that port 8765 is free, and try again.", "Remote viewing", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            RenderRemote();
            RenderActivity();
        };
        options.Controls.AddRange([_reach, _addresses, _remoteToggle]);
        layout.Controls.Add(options, 0, 1);
        _shareTranscripts.CheckedChanged += (_, _) => {
            // Restart revokes devices that may already have a transcript request in flight.
            if (_remote.Running) {
                _remote.Stop();
                _activity.Record("Remote", "Transcript sharing changed; reconnect paired devices after starting again.", DateTimeOffset.UtcNow);
            }
            RenderRemote();
            RenderActivity();
        };
        layout.Controls.Add(_shareTranscripts, 0, 2);
        _connectLink.Dock = DockStyle.Fill;
        _connectLink.BackColor = Theme.Card;
        _connectLink.ForeColor = Theme.Text;
        layout.Controls.Add(_connectLink, 0, 3);
        _remoteStatus.Dock = DockStyle.Fill;
        layout.Controls.Add(_remoteStatus, 0, 4);
        var copy = Theme.CreateButton("Copy connect link");
        copy.Click += (_, _) => {
            if (!string.IsNullOrEmpty(_connectLink.Text)) {
                try { Clipboard.SetText(_connectLink.Text); } catch (System.Runtime.InteropServices.ExternalException) { }
            }
        };
        layout.Controls.Add(copy, 0, 5);
        ConfigureList(_devices);
        layout.Controls.Add(_devices, 0, 6);
        var revoke = Theme.CreateButton("Revoke selected device");
        revoke.Click += (_, _) => {
            if (_devices.SelectedIndex is var index && index >= 0 && index < _deviceIds.Count) {
                _remote.Revoke(_deviceIds[index]);
                _activity.Record("Remote", "Paired device revoked.", DateTimeOffset.UtcNow);
                RenderActivity();
            }
        };
        layout.Controls.Add(revoke, 0, 7);
        RefreshAddresses();
        return layout;
    }

    private string AccessPolicy() => _reach.SelectedIndex switch { 1 => "private", 2 => "tailnet", _ => "loopback" };

    private void RefreshAddresses() {
        _addresses.Items.Clear();
        if (_reach.SelectedIndex != 0) {
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up)) {
                foreach (var address in adapter.GetIPProperties().UnicastAddresses.Select(a => a.Address).Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)) {
                    var bytes = address.GetAddressBytes();
                    var tailnet = bytes[0] == 100 && bytes[1] is >= 64 and <= 127;
                    var local = bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) || (bytes[0] == 192 && bytes[1] == 168);
                    if (tailnet || (_reach.SelectedIndex == 1 && local)) {
                        _addresses.Items.Add(address.ToString());
                    }
                }
            }
        }
        if (_addresses.Items.Count == 0) {
            _addresses.Items.Add("127.0.0.1");
        }
        _addresses.SelectedIndex = 0;
    }

    private void RenderRemote() {
        if (IsDisposed || Disposing) {
            return;
        }
        var running = _remote.Running;
        _reach.Enabled = !running;
        _remoteToggle.Text = running ? "Stop sharing" : "Start sharing";
        _connectLink.Text = running && _remote.Token is { } token && _addresses.SelectedItem is string address ? $"http://{address}:8765/?token={token}" : "";
        _connectLink.UseSystemPasswordChar = _settings.HideSensitiveInfo;
        _remoteStatus.Text = "Off. Recent conversations stay on this computer.";
        if (running) {
            _remoteStatus.Text = _remote.PairingCode is { } code
                ? $"Verification code: {code} (rotates every 2 minutes). Devices below can be revoked."
                : "Starting server... If this persists, stop and check port 8765.";
            if (_settings.HideSensitiveInfo && _remote.PairingCode is not null) {
                _remoteStatus.Text = "Sharing is on. Pairing details hidden on this PC.";
            }
        }
        var selected = _devices.SelectedIndex >= 0 && _devices.SelectedIndex < _deviceIds.Count ? _deviceIds[_devices.SelectedIndex] : null;
        _devices.Items.Clear();
        _deviceIds.Clear();
        try {
            using var json = JsonDocument.Parse(_remote.Devices);
            if (json.RootElement.ValueKind == JsonValueKind.Object && json.RootElement.TryGetProperty("devices", out var devices)) {
                foreach (var device in devices.EnumerateArray()) {
                    _deviceIds.Add(device.GetProperty("id").GetString()!);
                    _devices.Items.Add(_settings.HideSensitiveInfo ? $"Paired device {_deviceIds.Count}"
                        : $"{device.GetProperty("name").GetString()} - {device.GetProperty("id").GetString()}");
                }
            }
        } catch (JsonException) {
        }
        var selectedIndex = selected is null ? -1 : _deviceIds.IndexOf(selected);
        _devices.SelectedIndex = selectedIndex;
    }

    private void DispatchRemote(Action action) {
        try {
            if (!IsDisposed && IsHandleCreated && !_exitRequested) {
                BeginInvoke(action);
            }
        } catch (InvalidOperationException) { }
    }

    private Task ScanSessionsAsync() {
        if (_activeScan.IsCompleted) {
            _activeScan = RunSessionScanAsync();
        }
        return _activeScan;
    }

    private async Task RunSessionScanAsync() {
        var settings = _settings;
        try {
            var result = await Task.Run(() => SessionCatalog.Scan(settings, _lifetime.Token), _lifetime.Token);
            if (!CanApplyRefreshResults() || settings != _settings) {
                return;
            }
            _sessions = result.Sessions;
            _scanIncomplete = result.Incomplete;
            RenderSessionList();
        } catch (OperationCanceledException) { } catch (Exception) {
            if (!CanApplyRefreshResults()) {
                return;
            }
            _sessions = [];
            _sessionList.Items.Clear();
            _scanStatus.Text = "Session history could not be read. Check the configured provider directories.";
        }
    }

    private void RenderSessionList() {
        var provider = _sessionProvider.SelectedIndex switch { 1 => "claude", 2 => "codex", _ => null };
        var visible = SessionFilter.Apply(_sessions, provider, _settings.HideSensitiveInfo ? "" : _sessionSearch.Text);
        _scanStatus.Text = $"{visible.Count} of {_sessions.Count} recent conversations (not live agents). Refreshes every 15 seconds."
            + (_settings.HideSensitiveInfo ? " Reveal sensitive info to search." : "")
            + (_scanIncomplete ? " Some history was unreadable or exceeded scan limits." : "");
        _sessionList.BeginUpdate();
        _sessionList.Items.Clear();
        foreach (var session in visible) {
            _sessionList.Items.Add(new ListViewItem([session.Provider == "claude" ? "Claude Code" : "Codex",
                _settings.HideSensitiveInfo ? "Conversation hidden" : session.Title, session.Modified.ToLocalTime().ToString("g")]));
        }
        _sessionList.EndUpdate();
    }

    private void PublishRemote() => _remote.Publish(_latestSnapshots, _sessions, _shareTranscripts.Checked);

    private void RenderActivity() {
        _sessionSummary.Text = _activity.Describe(_latestSnapshots, DateTimeOffset.UtcNow);
        _eventList.BeginUpdate();
        _eventList.Items.Clear();
        foreach (var entry in _activity.Events) {
            var detail = _settings.HideSensitiveInfo ? "Details hidden" : entry.Detail;
            _eventList.Items.Add($"{entry.At.ToLocalTime():g}  {entry.Category}: {detail}");
        }
        _eventList.EndUpdate();
    }
}
