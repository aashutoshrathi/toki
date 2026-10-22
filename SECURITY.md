# Security Policy

## Supported versions

Security fixes go into the latest stable release. Betas get fixes too while they are the newest
build on their channel. Older versions are not patched; update from Toki's menu or with
`brew upgrade --cask toki`.

| Version | Supported |
|:---|:---|
| Latest 3.x stable | Yes |
| Current 3.x beta | Yes |
| Anything older | No |

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Email **aashutoshrathi@gmail.com** with:

- the Toki version (for example v3.3.9) and your macOS version,
- what an attacker can do and what they need first (network position, a paired session, local
  access),
- steps or a script to reproduce it, and
- a proposed fix, if you have one.

You should get a reply within 7 days. Once the issue is confirmed, the fix ships in a release and
the changelog credits you, unless you would rather not be named. Please give the fix a chance to
ship before you publish details.

## What is in scope

Remote Control matters most. Its companion server (`Sources/Toki/Resources/toki_remote.py`) and
web app (`Sources/Toki/Resources/webui/`) let a paired phone type into the terminal an agent is
running in, so anything that gets past pairing is command execution on the Mac. See
[docs/remote-control.md](docs/remote-control.md) for how pairing, sessions and network access
are meant to work, and [.oss-scanner/threat_model.md](.oss-scanner/threat_model.md) for how
reports are rated.

Also in scope: how Toki reads and stores provider credentials, the provider API clients, and the
updater.

Not a vulnerability: a paired session doing what Remote Control is for, behavior that follows from
choosing the **Custom** host or `--access any`, and attacks that need code already running as the
same macOS user.
