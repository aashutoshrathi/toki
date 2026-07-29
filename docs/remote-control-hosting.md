# Remote Control: connect-from-anywhere hosting plan

The in-app Remote Control Server serves its own web UI over the local network today. This
document plans the "connect from anywhere" upgrade: a statically hosted UI that reaches the Mac
over Tailscale HTTPS, using host and token passed as URL params.

Status: planned, not built. The pieces below can land independently.

## The flow

```
Phone browser
  -> https://remote.toki.aashutosh.dev/?host=<mac>.<tailnet>.ts.net&token=XYZ   (Vercel, HTTPS)
       app.js reads host + token, calls:
  -> https://<mac>.<tailnet>.ts.net/api/...?token=XYZ                            (Tailscale HTTPS)
       tailscale serve proxies to the Mac's server on 127.0.0.1:8765
```

Access requires two independent gates: a valid **token** and the phone being on the user's
**tailnet**.

## Why hosting needs Tailscale

A page served over HTTPS (Vercel, GitHub Pages, anything) cannot `fetch()` a plain HTTP endpoint:
browsers block it as mixed content. The only HTTP exception is `localhost`, which on the phone
means the phone itself, not the Mac. So a hosted UI can only reach the Mac if the Mac's API is
also HTTPS. `tailscale serve` provides that with a real, phone-trusted certificate. Over plain
LAN HTTP the hosted UI is a dead end; that path stays served directly from the Mac instead.

## Pieces

### 1. Frontend params + CORS (code, this repo)

- `webui/app.js`: if `?host=` is present, use `https://<host>` as the API base; otherwise keep
  same-origin so the locally served path still works.
- Python server: send `Access-Control-Allow-Origin` (locked to the hosted origin), allow the
  `Content-Type` header, and answer `OPTIONS` preflight. The page origin (hosted) and the API
  origin (tailnet host) differ, so cross-origin handling is required.

### 2. Static hosting (manual, one-time)

Vercel or Cloudflare Pages, whichever the maintainer prefers (functionally equivalent here):

- New project, import the repo, set **Root Directory = `Sources/Toki/Resources/webui`**, framework
  preset "Other" (static, no build step).
- Add the domain `remote.toki.aashutosh.dev` as a CNAME on the existing domain (no new domain).
- Auto-deploys on every push to `main`; pull requests get preview URLs. This is the same source
  the app bundles, so there is no drift.

### 3. Tailscale HTTPS on the Mac

- One-time in the tailnet admin console: enable MagicDNS and HTTPS certificates.
- Front the API with HTTPS: `tailscale serve --bg 443 http://127.0.0.1:8765`, giving
  `https://<mac>.<tailnet>.ts.net`.
- Open decision: the app runs `tailscale serve` automatically when Host is set to Tailscale
  (shelling out to the `tailscale` CLI and discovering the name via `tailscale status --json`), or
  the maintainer runs it manually. Automatic is smoother but assumes the CLI is installed and
  HTTPS is enabled on the tailnet.

### 4. App Connect flow (code, this repo)

- When Host is Tailscale, build the QR and connect URL as
  `https://remote.toki.aashutosh.dev/?host=<tailnet-host>&token=<token>` instead of the raw local
  URL.
- The Mac's tailnet hostname comes from `tailscale status --json`.

## Follow-on: mobile push notifications

Once the UI is on HTTPS it can become an installable PWA (web app manifest plus a service worker),
which unlocks Web Push so the phone is notified when an agent needs input. On iOS this requires the
user to Add to Home Screen (Web Push is limited to installed PWAs, iOS 16.4+). This is why the
hosting work is a prerequisite for notifications.

## Suggested order

1. Frontend params + CORS (piece 1) and the app Connect flow (piece 4) in code.
2. Static hosting project (piece 2) and Tailscale HTTPS (piece 3) set up by the maintainer.
3. Wire the tailnet hostname into the Connect flow and verify end to end.
4. PWA and Web Push as a later follow-on.
