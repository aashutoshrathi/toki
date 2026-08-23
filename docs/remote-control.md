# Remote Control

Remote Control lets you watch your running agents from your phone and reply to them: approve a
permission prompt, answer a question, send a message, clear a session, change the model. Toki starts a small HTTP
server on this Mac, your phone opens a web app, and the two talk directly. Nothing goes through a
cloud service, and no transcript leaves your machine.

**What this actually is:** replying from your phone means typing into the terminal your agent is
running in. That is arbitrary command execution on your Mac. Everything below is about making sure
only you can do it.

## Quick start

1. Open **Settings → Remote Control Server** and turn it on.
2. Pick a **Reach**:
   - **On my network** — the phone must be on the same Wi-Fi. No setup.
   - **From anywhere** — [Tailscale](https://tailscale.com/download). This is the recommended
     path and the one the rest of this page assumes.
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

That session lasts as long as it says it does: the phone keeps it until the lifetime you chose runs
out, so closing the browser, locking the phone, or leaving the tab in the background does not send
you back to the six-digit code. It is stored on the device that paired, which is what a session of
hours-to-days means in practice — **Revoke** in Settings is what ends one early, and it takes
effect on that device's next request.

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

This holds through a proxy too. `tailscale serve` relays from this Mac, so its requests arrive
looking local; Toki reads the address it is relaying for and applies the same rule. If you have
Tailscale **Funnel** enabled, or any other reverse proxy pointed at port 8765, a request from the
public internet is refused under the Tailscale setting rather than admitted because it arrived
over loopback. **Localhost** holds the same line: it means this Mac even when something running
on this Mac is relaying for someone else.

The single exception is **Cloudflare Tunnel**, where relaying the public internet to your Mac is
the thing you asked for.

**Changing the Host restarts the server.** That is deliberate: a narrowed setting has to take
effect immediately, and it also invalidates every paired session. You will need to reconnect your
phone.

### Why Tailscale is the recommendation

Tailscale is the only option that is private by construction. Your Mac and your phone join a
network only your devices are on, traffic between them is encrypted end to end, and no part of it
is reachable from the public internet. Every other "from anywhere" option works by putting your
Mac behind an address strangers can at least send packets to.

If you can run Tailscale, run Tailscale. The other options exist for when you cannot.

### Where the app itself comes from

Under **Advanced → App** you choose where the phone loads the interface from:

| App | Where the code comes from |
|:---|:---|
| **Same as host** (recommended) | This Mac, over the same connection |
| Toki RC (hosted) | `rc.toki.aashutosh.dev`, a static web host |
| Local / Local network | This Mac, at a specific address |

**Same as host** is the safer default because there is no third party in it at all. The hosted
option exists because it is convenient: it works before you have `tailscale serve` running, and a
phone can reach it without the Mac serving HTTPS.

The tradeoff is worth stating plainly. The hosted page only serves the interface, and your agent
data never touches it: transcripts and replies travel directly between your phone and your Mac
over the tailnet. But it is still JavaScript loaded from a web server, and that JavaScript is
handed your connection token. If that host were ever compromised, the code it served could use
your token against your Mac. Serving the app from your own machine removes that possibility
rather than mitigating it.

## Paired devices

While the server is running, Settings lists every device currently holding a session, with a
**Revoke** button on each. Revoking ends that one session immediately: the phone's next request
fails and it drops back to the verification screen. Other devices are unaffected.

Each row shows:

- **Name** — worked out from the browser the device identifies itself as, for example
  "iPhone (Safari)". This is a convenience for telling two of your own devices apart, not proof of
  identity: a client writes its own User-Agent and can claim to be anything.
- **ID** — a random identifier Toki assigns at pairing. This is what actually names the session.
  The device never sees it and cannot influence it.
- **Address** — where the device connected from, when that is knowable. It reads **via proxy**
  when it is not: `tailscale serve` and `cloudflared` both relay from this Mac, so the address
  Toki sees is the relay, not the phone. Toki says so rather than showing you `127.0.0.1` and
  letting you read it as the device.
- **Last seen** and **expires**.

There is deliberately no way to see or revoke devices from the phone. The list travels over the
private pipe between Toki and its server, never over HTTP, so a paired phone cannot enumerate your
other devices or cut them off.

**There is no MAC address, and there cannot be.** MAC addresses are link-layer: they do not
survive routing, and over Tailscale the peer is an encrypted tunnel endpoint that has none at all.
Nothing in an HTTP request carries one. The device ID is the durable identifier here.

## Gotchas

### The verification code rotates every two minutes

If you scan the QR, walk to another room, and then type the code you memorised, it has probably
already changed. Look at the Mac again. The code on screen is always the current one.

### Toki must stay running, and the Mac must stay awake

Sessions live in the server process. Quitting Toki, or turning Remote Control off, ends every
session immediately. A sleeping Mac is unreachable; if you rely on this, set the Mac not to sleep
on power.

### Read-only sessions

Agents without a terminal — Codex desktop, VS Code extensions, anything not attached to a TTY —
show up but cannot be replied to. There is no keyboard to type into. They are grouped under
**Read-only** at the bottom of the picker, so the agent that is actually waiting on you is the one
selected by default.

### Changing an agent's model

The **Model** button in the composer opens the running CLI's own model picker (`/model` for
Claude, Codex, fx, and Antigravity; `/models` for OpenCode) and then mirrors that picker on the
phone so you can see the options and the highlighted row. You drive the selection with the same
**↑ ↓ Tab Enter** controls used to answer any other picker, and **Done** closes the mirror.

The mirror reads the visible terminal through the same routes replies are typed into: tmux, iTerm,
and Terminal. An agent in a terminal Toki cannot read that way still opens its picker on the Mac,
but the phone shows nothing to steer by, so the mirror reports it has no route.

### The first connection can be blocked by the macOS firewall

macOS prompts once to allow incoming connections for `python3`. If you dismissed that prompt, the
phone will not connect and there is no second prompt. Fix it in **System Settings → Network →
Firewall → Options**.

### Guest and public Wi-Fi isolate devices from each other

Many networks enable AP isolation, which stops your phone from reaching your Mac even though both
are "on the same Wi-Fi". Nothing on the Mac can fix this. Use Tailscale.

### Tailscale needs MagicDNS and HTTPS certificates

"From anywhere" over Tailscale needs both enabled in the tailnet admin console, and
`tailscale serve` fronting the port so the phone gets a real certificate. Toki runs the serve
command for you when you start the server with Tailscale as the host — it does not wait to be
asked. It will not overwrite an existing handler on port 443, though: if something else is already
served there, Toki warns and leaves the replacement to an explicit click.

Two things stop Toki from enabling it, and it says which one you hit and what clears it. Tailscale
only lets its *operator* change serve settings, which is fixed once with
`sudo tailscale set --operator=$USER`. And a tailnet without HTTPS Certificates has no certificate
to serve with, which is a switch in the admin console. If Toki cannot find a `tailscale` command at
all — the Mac App Store build ships no usable CLI — it hands you the exact command to run instead.

If `tailscale status` cannot be read, you can type the `.ts.net` host by hand in Settings, and the
HTTPS status and its Enable button still appear.

### Cloudflare Tunnel is a public URL, and is not recommended

A quick tunnel puts your Mac behind an address anyone on the internet can reach. The link token
and rotating code still gate it, and Toki restricts the server to accepting only the tunnel
process itself, so this is not an open door. But it is the only option where a stranger can
attempt the door at all, and the only one where your requests pass through a third party's edge.

It is offered last in the Host list, labelled **public**, and Toki warns while it is selected.
Use it when you genuinely cannot run Tailscale, and turn Remote Control off when you are done.
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
invalidates the link. To cut off one device without disturbing the others, use **Revoke** on its
row in the paired devices list. Remote Control is off by default and stays off until you turn it
on.

## Related

- [Connect-from-anywhere hosting plan](remote-control-hosting.md) — how the hosted UI, CORS, and
  `tailscale serve` fit together.
- [Features](features.md) — the rest of what Toki does.
