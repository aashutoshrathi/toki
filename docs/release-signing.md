# Release signing and notarization

The release workflow (`.github/workflows/release.yml`) signs and notarizes the app when the
Apple secrets below are present, and otherwise falls back to ad-hoc signing (unsigned, not
notarizable) so releases still build. This page lists exactly what to collect and where each
value comes from.

Everything here comes from an Apple Developer Program account (99 USD per year). If you are
using someone else's developer identity, note that the app ships under their name and team, and
the `.p12` contains their private key, so treat these as sensitive credentials: store them only
as encrypted GitHub Actions secrets, never in the repository.

## What you need

Two things are required: a signing certificate and a notarization credential. The certificate
and the notarization credential must belong to the same Apple team.

### 1. Signing: Developer ID certificate (all three required)

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | base64 of a **Developer ID Application** certificate exported as `.p12` (certificate plus private key) |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | the identity string, for example `Developer ID Application: Jane Doe (AB12CD34EF)` |

The certificate must be of type **Developer ID Application** (for distribution outside the App
Store). "Apple Development" and "Mac App Distribution" certificates will not work, and an ad-hoc
signed build cannot be notarized.

To create and export it:

1. In Xcode, go to Settings > Accounts > Manage Certificates, then add a **Developer ID
   Application** certificate. (Or create one at developer.apple.com > Certificates.)
2. In Keychain Access, right-click the `Developer ID Application: ...` certificate and choose
   Export, saving a `.p12` and setting a password. That password is `APPLE_CERTIFICATE_PASSWORD`.
3. Find the identity string for `APPLE_SIGNING_IDENTITY` with:

   ```bash
   security find-identity -v -p codesigning
   ```

### 2. Notarization: pick one style

**Style A, App Store Connect API key (recommended, does not expire, independently revocable):**

| Secret | What it is |
| --- | --- |
| `APPLE_API_KEY_P8` | base64 of the `.p8` key file |
| `APPLE_API_KEY_ID` | the Key ID |
| `APPLE_API_ISSUER` | the Issuer ID (a UUID) |

Generate the key in App Store Connect > Users and Access > Integrations (Keys). The `.p8` file
can only be downloaded once. The Key ID is shown next to the key, and the Issuer ID is at the top
of the Keys page.

**Style B, Apple ID and app-specific password:**

| Secret | What it is |
| --- | --- |
| `APPLE_ID` | the Apple ID email |
| `APPLE_APP_SPECIFIC_PASSWORD` | an app-specific password from appleid.apple.com > Sign-In and Security |
| `APPLE_TEAM_ID` | the 10-character team ID (from developer.apple.com membership, or the parentheses in the signing identity) |

`notarize.sh` uses the API key style if it is set, otherwise the Apple ID style.

### Not required for betas

`HOMEBREW_TAP_TOKEN` is a GitHub token for the `homebrew-tap` repository. It is only used on
stable tags (no hyphen) to update the Homebrew cask. Beta tags such as `v2.5.3-beta.2` skip it.

## Setting the secrets

Prepare the base64 values:

```bash
base64 -i DeveloperID.p12 | pbcopy   # APPLE_CERTIFICATE_P12
base64 -i AuthKey_XXXX.p8 | pbcopy   # APPLE_API_KEY_P8
```

Then set each secret, either in the repository UI (Settings > Secrets and variables > Actions) or
with the GitHub CLI:

```bash
gh secret set APPLE_CERTIFICATE_P12 < <(base64 -i DeveloperID.p12)
gh secret set APPLE_CERTIFICATE_PASSWORD --body '...'
gh secret set APPLE_SIGNING_IDENTITY --body 'Developer ID Application: Jane Doe (AB12CD34EF)'
gh secret set APPLE_API_KEY_P8 < <(base64 -i AuthKey_XXXX.p8)
gh secret set APPLE_API_KEY_ID --body '...'
gh secret set APPLE_API_ISSUER --body '...'
```

Confirm what is already configured with `gh secret list`.

## Minimum set for signed, notarized builds

- Signing: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`
- Notarization: one style from section 2

With those in place, a tag push produces a signed and notarized DMG. Without them, the workflow
still builds and publishes an ad-hoc signed DMG.
