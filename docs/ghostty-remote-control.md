# Ghostty Remote Control

Toki supports agents running directly in Ghostty on macOS. Discovery and transcripts work the
same as every other terminal; replies, picker keys, navigation, and screen mirroring use Ghostty's
native macOS integration.

## Requirements

- A Ghostty build whose AppleScript `terminal` object exposes `tty`. The locally tested build is
  `1.3.2-main-+d9840f3c8`; the property is also present on Ghostty's current `main` branch and is
  planned for 1.4. Ghostty 1.3.0 and 1.3.1 have AppleScript input but no safe way to distinguish
  two terminals by tty, so Toki deliberately does not guess by title or working directory.
- **Automation → Ghostty** permission for navigation and replies.
- **Accessibility → Toki** permission for bare-Ghostty screen and model-picker mirroring.
- Ghostty's `macos-applescript` setting enabled (the default).

Ghostty documents its scripting API at
[AppleScript (macOS)](https://ghostty.org/docs/features/applescript). The current dictionary is
[`macos/Ghostty.sdef`](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef).

## Routes

| Session | Replies and keys | Screen/model mirror |
|:---|:---|:---|
| Ghostty around tmux | `tmux send-keys` | `tmux capture-pane` |
| Bare Ghostty | AppleScript `input text` / `send key`, selected by tty | Ghostty's focused `AXTextArea` value |

tmux remains first when it is present. For a bare terminal, Toki receives the host bundle ID from
its canonical agent scanner and addresses Ghostty directly, so it does not probe or prompt for
unrelated terminal apps.

## Screen mirroring tradeoff

Ghostty exposes terminal input through AppleScript but intentionally exposes no `contents`
property comparable to iTerm or Terminal.app. The terminal view does expose its text to macOS
Accessibility as an `AXTextArea`, so Toki:

1. finds the Ghostty terminal whose tty exactly matches the agent;
2. focuses that terminal through AppleScript;
3. reads the focused accessibility value; and
4. applies the same line and byte limits as the other screen routes.

Focusing is necessary because the accessibility element has no tty or Ghostty surface identifier.
Opening a screen or model mirror can therefore bring Ghostty and the selected tab to the front.
Ghostty's accessibility value is the terminal buffer, not a separate visible-viewport value; Toki
shows its recent bounded tail, which is where an interactive picker is rendered.

Toki does not use `write_screen_file`: that action communicates the generated path through the
system clipboard, creating races and potentially replacing rich clipboard data.

## Failure behavior

If Ghostty is too old, AppleScript is disabled, a permission is missing, or the tty disappears,
the route fails without trying a different Ghostty tab. Running the agent inside tmux remains the
compatible fallback for older Ghostty builds and does not require Ghostty automation support.
