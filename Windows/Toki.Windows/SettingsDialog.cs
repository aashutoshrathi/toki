using Toki.Core;

namespace Toki.Windows;

internal sealed class SettingsDialog : Form {
    private readonly TextBox _claudeDirectoryTextBox = new();
    private readonly TextBox _codexHomeTextBox = new();
    private readonly TextBox _codexExecutableTextBox = new();
    private readonly CheckBox _notificationsCheckBox = new();
    private readonly CheckBox _doNotDisturbCheckBox = new();
    private readonly Label _errorLabel = new();
    private readonly CheckBox _privacyCheckBox = new();
    private readonly CheckBox _startupCheckBox = new();
    private readonly bool? _startupRegistered;
    private readonly Button _saveButton;
    private readonly Button _cancelButton;

    internal SettingsDialog(AppSettings settings, bool? startupRegistered) {
        _startupRegistered = startupRegistered;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Theme.Background;
        ClientSize = new Size(720, 550);
        Font = new Font("Segoe UI", 9, FontStyle.Regular, GraphicsUnit.Point);
        ForeColor = Theme.Text;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        KeyPreview = true;
        MaximizeBox = false;
        MinimizeBox = false;
        Name = "TokiSettingsDialog";
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        Text = "Toki Settings - Windows Preview";

        var root = new TableLayoutPanel {
            BackColor = Theme.Background,
            ColumnCount = 1,
            Dock = DockStyle.Fill,
            Padding = new Padding(24),
            RowCount = 6
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 150));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 152));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));

        root.Controls.Add(Theme.CreateLabel("Settings", 18, Theme.Text, true), 0, 0);
        root.Controls.Add(Theme.CreateLabel("Leave a path blank to use automatic discovery. Overrides must be absolute paths that exist.", 9.5f, Theme.MutedText), 0, 1);

        var fields = new TableLayoutPanel {
            BackColor = Theme.Background,
            ColumnCount = 3,
            Dock = DockStyle.Fill,
            RowCount = 3
        };
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        for (var row = 0; row < 3; row++) {
            fields.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        }

        ConfigureTextBox(_claudeDirectoryTextBox, "ClaudeDirectoryTextBox", settings.ClaudeConfigDirectory);
        ConfigureTextBox(_codexHomeTextBox, "CodexHomeTextBox", settings.CodexHome);
        ConfigureTextBox(_codexExecutableTextBox, "CodexExecutableTextBox", settings.CodexExecutable);

        AddDirectoryRow(fields, 0, "&Claude directory", _claudeDirectoryTextBox, "ClaudeConfigDirectory");
        AddDirectoryRow(fields, 1, "Codex &home", _codexHomeTextBox, "CodexHome");
        AddExecutableRow(fields, 2, "Codex &executable", _codexExecutableTextBox);
        root.Controls.Add(fields, 0, 2);

        var options = new FlowLayoutPanel {
            BackColor = Theme.Background,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false
        };
        _notificationsCheckBox.AutoSize = true;
        _notificationsCheckBox.Checked = settings.NotificationsEnabled;
        _notificationsCheckBox.ForeColor = Theme.Text;
        _notificationsCheckBox.Margin = new Padding(0, 8, 28, 8);
        _notificationsCheckBox.Name = "NotificationsCheckBox";
        _notificationsCheckBox.Text = "Show &low-quota notifications";
        _doNotDisturbCheckBox.AutoSize = true;
        _doNotDisturbCheckBox.Checked = settings.DoNotDisturb;
        _doNotDisturbCheckBox.ForeColor = Theme.Text;
        _doNotDisturbCheckBox.Margin = new Padding(0, 8, 0, 8);
        _doNotDisturbCheckBox.Name = "DoNotDisturbCheckBox";
        _doNotDisturbCheckBox.Text = "&Do not disturb";
        options.Controls.Add(_notificationsCheckBox);
        options.Controls.Add(_doNotDisturbCheckBox);
        _privacyCheckBox.AutoSize = true;
        _privacyCheckBox.Text = "Hide sensitive info on this PC";
        _privacyCheckBox.Name = "PrivacyCheckBox";
        _privacyCheckBox.Checked = settings.HideSensitiveInfo;
        _privacyCheckBox.CheckedChanged += (_, _) => MaskPaths();
        options.Controls.Add(_privacyCheckBox);
        _startupCheckBox.AutoSize = true;
        _startupCheckBox.Text = "Launch at Windows sign-in (tray only)";
        _startupCheckBox.Name = "StartupCheckBox";
        _startupCheckBox.Checked = startupRegistered == true;
        _startupCheckBox.Enabled = startupRegistered is not null;
        options.Controls.Add(_startupCheckBox);
        var startupNote = Theme.CreateLabel(startupRegistered is null
            ? "Startup registration could not be read. Check Windows Startup apps."
            : "Windows Startup apps can override this registration.", 9, Theme.MutedText);
        options.Controls.Add(startupNote);
        MaskPaths();
        root.Controls.Add(options, 0, 3);

        _errorLabel.AutoSize = false;
        _errorLabel.AutoEllipsis = true;
        _errorLabel.Dock = DockStyle.Fill;
        _errorLabel.ForeColor = Theme.Error;
        _errorLabel.Name = "SettingsErrorLabel";
        _errorLabel.TextAlign = ContentAlignment.MiddleLeft;
        root.Controls.Add(_errorLabel, 0, 4);

        var buttons = new FlowLayoutPanel {
            BackColor = Theme.Background,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false
        };
        _saveButton = Theme.CreateButton("Save", true);
        _saveButton.Name = "SaveSettingsButton";
        _saveButton.Click += SaveButton_Click;
        _cancelButton = Theme.CreateButton("Cancel");
        _cancelButton.DialogResult = DialogResult.Cancel;
        _cancelButton.Name = "CancelSettingsButton";
        buttons.Controls.Add(_saveButton);
        buttons.Controls.Add(_cancelButton);
        root.Controls.Add(buttons, 0, 5);

        Controls.Add(root);
        AcceptButton = _saveButton;
        CancelButton = _cancelButton;
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        WindowTheme.Apply(Handle);
    }

    internal AppSettings? Settings { get; private set; }
    internal bool? LaunchAtLoginEnabled {
        get {
            if (_startupRegistered is null || (_startupRegistered == false && !_startupCheckBox.Checked)) {
                return null;
            }
            return _startupCheckBox.Checked;
        }
    }

    private void MaskPaths() {
        foreach (var box in new[] { _claudeDirectoryTextBox, _codexHomeTextBox, _codexExecutableTextBox }) {
            box.UseSystemPasswordChar = _privacyCheckBox.Checked;
        }
    }

    private static void ConfigureTextBox(TextBox textBox, string name, string? value) {
        textBox.BackColor = Theme.Card;
        textBox.BorderStyle = BorderStyle.FixedSingle;
        textBox.Dock = DockStyle.Fill;
        textBox.ForeColor = Theme.Text;
        textBox.Name = name;
        textBox.Text = value ?? string.Empty;
    }

    private static Label CreateFieldLabel(string text) {
        var label = Theme.CreateLabel(text, 9.5f, Theme.Text);
        label.AutoSize = false;
        label.Dock = DockStyle.Fill;
        label.TextAlign = ContentAlignment.MiddleLeft;
        return label;
    }

    private static Button CreateBrowseButton() {
        var button = Theme.CreateButton("Browse...");
        button.Margin = new Padding(8, 2, 0, 2);
        button.MinimumSize = new Size(84, 32);
        return button;
    }

    private static void AddDirectoryRow(TableLayoutPanel fields, int row, string label, TextBox textBox, string dialogTitle) {
        var browseButton = CreateBrowseButton();
        browseButton.Click += (_, _) => {
            using var dialog = new FolderBrowserDialog {
                Description = $"Select {dialogTitle}",
                ShowNewFolderButton = false,
                UseDescriptionForTitle = true
            };
            if (Directory.Exists(textBox.Text)) {
                dialog.SelectedPath = textBox.Text;
            }
            if (dialog.ShowDialog() == DialogResult.OK) {
                textBox.Text = dialog.SelectedPath;
            }
        };
        fields.Controls.Add(CreateFieldLabel(label), 0, row);
        fields.Controls.Add(textBox, 1, row);
        fields.Controls.Add(browseButton, 2, row);
    }

    private static void AddExecutableRow(TableLayoutPanel fields, int row, string label, TextBox textBox) {
        var browseButton = CreateBrowseButton();
        browseButton.Click += (_, _) => {
            using var dialog = new OpenFileDialog {
                CheckFileExists = true,
                CheckPathExists = true,
                Filter = "Codex executable or npm entry|*.exe;*.js;*.mjs;*.cjs|All files|*.*",
                Title = "Select Codex executable"
            };
            if (File.Exists(textBox.Text)) {
                dialog.FileName = textBox.Text;
            }
            if (dialog.ShowDialog() == DialogResult.OK) {
                textBox.Text = dialog.FileName;
            }
        };
        fields.Controls.Add(CreateFieldLabel(label), 0, row);
        fields.Controls.Add(textBox, 1, row);
        fields.Controls.Add(browseButton, 2, row);
    }

    private void SaveButton_Click(object? sender, EventArgs e) {
        var claudeDirectory = NormalizeInput(_claudeDirectoryTextBox.Text);
        var codexHome = NormalizeInput(_codexHomeTextBox.Text);
        var codexExecutable = NormalizeInput(_codexExecutableTextBox.Text);

        if (!TryValidateDirectory(claudeDirectory, "Claude directory", out claudeDirectory, out var error)) {
            ShowValidationError(error, _claudeDirectoryTextBox);
            return;
        }
        if (!TryValidateDirectory(codexHome, "Codex home", out codexHome, out error)) {
            ShowValidationError(error, _codexHomeTextBox);
            return;
        }
        if (!TryValidateExecutable(codexExecutable, out codexExecutable, out error)) {
            ShowValidationError(error, _codexExecutableTextBox);
            return;
        }

        Settings = new AppSettings(
            claudeDirectory,
            codexHome,
            codexExecutable,
            _notificationsCheckBox.Checked,
            _doNotDisturbCheckBox.Checked,
            _privacyCheckBox.Checked);
        DialogResult = DialogResult.OK;
        Close();
    }

    private static string? NormalizeInput(string value) {
        var trimmed = value.Trim();
        if (trimmed.Length >= 2 && trimmed[0] == '"' && trimmed[^1] == '"') {
            trimmed = trimmed[1..^1];
        }
        return trimmed.Length == 0 ? null : Environment.ExpandEnvironmentVariables(trimmed);
    }

    private static bool TryValidateDirectory(string? value, string displayName, out string? normalized, out string error) {
        normalized = value;
        error = string.Empty;
        if (value is null) {
            return true;
        }

        try {
            if (!Path.IsPathFullyQualified(value)) {
                error = $"{displayName} must be an absolute path.";
                return false;
            }
            if (!Directory.Exists(value)) {
                error = $"{displayName} does not exist or is not a directory.";
                return false;
            }
            normalized = Path.GetFullPath(value);
            return true;
        } catch (Exception) {
            error = $"{displayName} is not a valid directory path.";
            normalized = null;
            return false;
        }
    }

    private static bool TryValidateExecutable(string? value, out string? normalized, out string error) {
        normalized = value;
        error = string.Empty;
        if (value is null) {
            return true;
        }

        try {
            if (!Path.IsPathFullyQualified(value)) {
                error = "Codex executable must be an absolute path.";
                return false;
            }
            var extension = Path.GetExtension(value);
            if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase) || extension.Equals(".bat", StringComparison.OrdinalIgnoreCase)) {
                error = "Choose codex.exe or codex.js, not a .cmd or .bat launcher.";
                return false;
            }
            if (!File.Exists(value)) {
                error = "Codex executable does not exist or is not a file.";
                return false;
            }
            normalized = Path.GetFullPath(value);
            return true;
        } catch (Exception) {
            error = "Codex executable is not a valid file path.";
            normalized = null;
            return false;
        }
    }

    private void ShowValidationError(string error, TextBox textBox) {
        _errorLabel.Text = error;
        textBox.Focus();
        textBox.SelectAll();
    }
}
