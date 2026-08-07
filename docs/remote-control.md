# Remote Control

Remote Control lets you watch your running agents from your phone and reply to them: approve a
permission prompt, answer a question, send a message, clear a session. Toki starts a small HTTP
server on this Mac, your phone opens a web app, and the two talk directly. Nothing goes through a
cloud service, and no transcript leaves your machine.

**What this actually is:** replying from your phone means typing into the terminal your agent is
running in. That is arbitrary command execution on your Mac. Everything below is about making sure
only you can do it.

## Quick start

1. Open **Settings → Remote Control Server** and turn it on.
2. Pick a **Reach**:
   - **On my network** — the phone must be on the same Wi-Fi. No setup.
   - **From anywhere** — over Tailscale (recommended) or a Cloudflare tunnel.
3. Click **Connect**. Toki shows a QR code and a six-digit verification code.
4. Scan the QR with your phone's camera.
5. Type the six-digit code from your Mac's screen into the phone.

You are connected. On iOS, use **Share → Add to Home Screen** to install it as an app, which is
also what enables notifications when an agent needs you.

## How the security works

Three separate things must be true before a phone can type into your terminal:

| Gate | What it is | How it is obtained |
|:---|:---|:---|
| **Network** | The phone must be on a network the server answers | Same Wi-Fi, or your tailnet |
| **Link token** | A random secret in the connect link | Scanning the QR, or opening the link |
| **Verification code** | Six digits, rotating every two minutes | Read off your Mac's screen |

The QR code alone is not enough — someone who photographs your screen still needs the verification
code, which changes every two minutes. The code alone is not enough either. Five wrong codes in a
minute triggers a rate limit.

Passing all three exchanges the link for a **session token** that expires after the lifetime you
chose in Settings (12 hours by default, 2 days maximum). The session token is sent in an
`Authorization` header, so it stays out of your phone's browser history and out of the logs of
anything sitting between the phone and the Mac.

### Who can reach the server

The **Host** setting is not just a display preference — it decides which networks the server will
answer at all. Anything else is refused before authentication is even considered.

| Host | Answers requests from |
|:---|:---|
| Localhost | This Mac only |
| Tailscale | Your tailnet, plus this Mac |
| Local network | Your LAN and tailnet, plus this Mac |
| Cloudflare Tunnel | The tunnel process on this Mac (which relays the public URL) |
| Custom | Anywhere — you have named a host Toki cannot classify |

So with **Tailscale** selected, joining an airport Wi-Fi does not expose the port to that network,
even though the server is listening on all interfaces so `tailscale serve` and your phone can both
reach it.

**Changing the Host restarts the server.** That is deliberate: a narrowed setting has to take
effect immediately, and it also invalidates every paired session. You will need to reconnect your
phone.

## Gotchas

### The verification code rotates every two minutes

If you scan the QR, walk to another room, and then type the code you memorised, it has probably
already changed. Look at the Mac again. The code on screen is always the current one.

### Toki must stay running, and the Mac must stay awake

Sessions live in the server process. Quitting Toki, or turning Remote Control off, ends every
session immediately — which is the fastest way to revoke a phone you no longer trust. A sleeping
Mac is unreachable; if you rely on this, set the Mac not to sleep on power.

### Read-only sessions

Agents without a terminal — Codex desktop, VS Code extensions, anything not attached to a TTY —
show up but cannot be replied to. There is no keyboard to type into. They are grouped under
**Read-only** at the bottom of the picker, so the agent that is actually waiting on you is the one
selected by default.

### The first connection can be blocked by the macOS firewall

macOS prompts once to allow incoming connections for `python3`. If you dismissed that prompt, the
phone will not connect and there is no second prompt. Fix it in **System Settings → Network →
Firewall → Options**.

### Guest and public Wi-Fi isolate devices from each other

Many networks enable AP isolation, which stops your phone from reaching your Mac even though both
are "on the same Wi-Fi". Nothing on the Mac can fix this. Use Tailscale.

### Tailscale needs MagicDNS and HTTPS certificates

"From anywhere" over Tailscale needs both enabled in the tailnet admin console, and
`tailscale serve` fronting the port so the phone gets a real certificate. Toki can run the serve
command for you, but it will not overwrite an existing handler on port 443 — if something else is
already served there, Toki warns instead of silently replacing it. If `tailscale status` cannot be
read, you can type the `.ts.net` host by hand in Settings.

### Cloudflare Tunnel is a public URL

A quick tunnel puts your Mac behind an address anyone on the internet can reach. The link token
and verification code still gate it, but this is the widest option available and the only one
where a stranger can even attempt the door. Prefer Tailscale, which is private by construction.
Requires `brew install cloudflared`.

### The phone remembers the link

The connect link is stored on the phone so the installed app can reopen without rescanning. It is
removed by tapping the home icon in the app. The session token is dropped when the browser tab
closes.

### Notifications need the app installed

Web Push on iOS only works for a PWA added to the Home Screen (iOS 16.4+). In a normal Safari tab
you get the UI but no notifications.

### Transcripts are shown in full

Anything your agent prints, the phone can display: file contents, command output, keys an agent
happened to echo. The privacy toggle in the app masks chat titles and folder names for
shoulder-surfing, but it does not redact transcript bodies.

## Turning it off

The toggle in **Settings → Remote Control Server** stops the server, which ends every session and
invalidates the link. Remote Control is off by default and stays off until you turn it on.

## Related

- [Connect-from-anywhere hosting plan](remote-control-hosting.md) — how the hosted UI, CORS, and
  `tailscale serve` fit together.
- [Features](features.md) — the rest of what Toki does.
