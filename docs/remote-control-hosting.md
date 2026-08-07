# Remote Control: connect-from-anywhere hosting plan

The in-app Remote Control Server serves its own web UI over the local network today. This
document plans the "connect from anywhere" upgrade: a statically hosted UI that reaches the Mac
over Tailscale HTTPS, using host and token passed as URL params.

Status: frontend parameter routing, locked-down CORS, and the app connect flow are implemented.
Static hosting, DNS, and `tailscale serve` remain one-time maintainer setup.

## The flow

```
Phone browser
  -> https://rc.toki.aashutosh.dev/#host=<mac>.<tailnet>.ts.net&token=XYZ   (Vercel, HTTPS)
       app.js reads host + token, calls:
  -> https://<mac>.<tailnet>.ts.net/api/...?token=XYZ                            (Tailscale HTTPS)
       tailscale serve proxies to the Mac's server on 127.0.0.1:8765
```

Access requires three gates: a valid link **token**, the six-digit verification code shown
separately in Toki, and the phone being on the user's **tailnet**. The browser exchanges the link
token and code for a random session token that expires after the lifetime selected in Toki
(12 hours recommended, 2 days maximum). Five failed code attempts within a minute trigger a
temporary rate limit. The verification code rotates every two minutes; already verified sessions
remain valid for their selected lifetime.

## Why hosting needs Tailscale

A page served over HTTPS (Vercel, GitHub Pages, anything) cannot `fetch()` a plain HTTP endpoint:
browsers block it as mixed content. The only HTTP exception is `localhost`, which on the phone
means the phone itself, not the Mac. So a hosted UI can only reach the Mac if the Mac's API is
also HTTPS. `tailscale serve` provides that with a real, phone-trusted certificate. Over plain
LAN HTTP the hosted UI is a dead end; that path stays served directly from the Mac instead.

## Pieces

### 1. Frontend params + CORS (code, this repo)

- `webui/app.js`: if `#host=` is present, use `https://<host>` as the API base; otherwise keep
  same-origin so the locally served path still works.
- Hosted links put their parameters in the URL fragment so the static host never receives the
  connection token. Query parameters remain supported for links made from the original plan.
- Connect links therefore come in two shapes, and they are interchangeable: hosted
  (`https://rc.toki.aashutosh.dev/#host=<mac>.ts.net&token=…`, App set to Toki RC) and direct
  (`https://<mac>.ts.net/?token=…`, App set to Same as host). The in-page QR scanner resolves both
  into the host-plus-token pair the manual form asks for, so a QR built for one page still works
  when scanned on the other. Only a LAN link (`http://<ip>:8765/?token=…`) is unusable from the
  hosted page, because an HTTPS page cannot call a plain-HTTP address; the scanner names the host
  it can't reach rather than rejecting the code.
- Python server: send `Access-Control-Allow-Origin` (locked to the hosted origin), allow the
  `Content-Type` header, and answer `OPTIONS` preflight. The page origin (hosted) and the API
  origin (tailnet host) differ, so cross-origin handling is required.

### 2. Static hosting (manual, one-time)

Vercel or Cloudflare Pages, whichever the maintainer prefers (functionally equivalent here):

- New project, import the repo, set **Root Directory = `Sources/Toki/Resources/webui`**, framework
  preset "Other" (static, no build step).
- Add the domain `rc.toki.aashutosh.dev` as a CNAME on the existing domain (no new domain).
- Auto-deploys on every push to `main`; pull requests get preview URLs.

The source is the same one the app bundles, but the two do not update together, and that is a
compatibility constraint rather than a detail. The hosted page changes the moment a release lands
on `main`; the Mac it talks to changes whenever its owner updates. During a beta the drift runs the
other way, with `main` behind the release branch. So both directions have to work:

- **Old page, new server.** The server keeps accepting the session token from the query string,
  not only the `Authorization` header.
- **New page, old server.** The page tries the header, and on the 403 an older server answers
  with, falls back to the query string and remembers for the session.

Neither fallback can be dropped until the older side is gone. `Tests/test_remote_cross_version.js`
runs the page's real token-transport logic against a server of each vintage.

### 3. Tailscale HTTPS on the Mac

- One-time in the tailnet admin console: enable MagicDNS and HTTPS certificates.
- Front the API with HTTPS: `tailscale serve --bg 443 http://127.0.0.1:8765`, giving
  `https://<mac>.<tailnet>.ts.net`.
- The maintainer runs this command manually. The app does not overwrite an existing persistent
  Serve configuration on port 443.

### 4. App Connect flow (code, this repo)

- Host and App are separate settings. App can use the selected host, localhost,
  the detected local-network address, or the hosted Toki RC interface at
  `rc.toki.aashutosh.dev`.
- When App is `Toki RC (hosted)`, build the QR and connect URL as
  `https://rc.toki.aashutosh.dev/#host=<tailnet-host>&token=<token>`.
- The Mac's tailnet hostname comes from `tailscale status --json`.
- `rc.toki.aashutosh.dev` serves only static interface files. Agent discovery, transcripts, and replies
  stay on the Mac and travel directly between the browser and Mac over the tailnet.

## End-to-end verification

1. Start Toki's Remote Control Server and select **Tailscale** as the host.
2. Run `tailscale serve --bg 443 http://127.0.0.1:8765` on the Mac.
3. Select `Toki RC (hosted)` under App, then open Connect and copy its URL.
4. On a phone connected to the same tailnet, open the URL and enter the six-digit code shown
   separately in Toki.
5. Confirm agents load, then send a reply and verify it reaches the selected terminal agent.

The hosted UI accepts only `*.ts.net` API hosts. The API emits cross-origin headers only for
`https://rc.toki.aashutosh.dev`; other web origins cannot use the browser CORS path.

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
