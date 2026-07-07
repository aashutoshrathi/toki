# Contributing to Toki

Thanks for taking the time to improve Toki.

## Local Checks

Run these before opening a pull request:

```sh
swift build
scripts/build-app.sh
plutil -p .build/Toki.app/Contents/Info.plist
```

## Style

- Prefer small, focused changes.
- Keep SwiftUI views readable and avoid deeply nested logic in view bodies.
- Keep provider/API parsing defensive; usage payloads can drift.
- Do not log or expose credentials, access tokens, or raw auth payloads.
- Preserve legacy TokenBar config fallbacks unless a migration plan replaces them.

`swift-format` is not vendored in this repository today. Follow the surrounding Swift style and keep the compiler clean.

## Configuration

Use a local config while developing:

```sh
TOKI_CONFIG=/path/to/config.json swift run Toki
```

Never commit personal config files, auth files, or generated app bundles.
