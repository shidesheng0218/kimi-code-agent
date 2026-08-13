# GitHub Release Runbook

Kimi Agent Desktop is distributed directly from GitHub Releases, not the Mac App Store.

## Required GitHub Secrets

| Secret | Purpose |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` certificate. |
| `P12_PASSWORD` | Password for that `.p12`. |
| `KEYCHAIN_PASSWORD` | Ephemeral CI keychain password. |
| `KIMI_DEVELOPER_ID_APPLICATION` | Exact Developer ID Application certificate common name. |
| `APPLE_ID` | Apple ID used for notarization. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool`. |

Never place API keys, `.p12` files, private signing keys, or notarization passwords in the repository or release assets.

## Release Steps

1. Update release notes and verify `npm run verify` locally.
2. Create and push a semantic tag, for example `v1.4.0`.
3. The **Release macOS** workflow builds a universal app, signs it, submits it to Apple notarization, staples the app ticket, validates the DMG/ZIP, and creates a GitHub Release.
4. Verify the published Release contains the DMG, ZIP, and `SHA256SUMS` file.
5. Download the asset on a clean macOS account and confirm: launch, API setup, a local terminal command, a Browser task, and app restart recovery.

## Sparkle Update Feed

Automatic updates should only be enabled after an EdDSA public key and a signed `appcast.xml` are available. Keep the appcast in a GitHub Pages branch or another HTTPS static host. Do not enable automatic updates against an unsigned feed.

## Support Boundaries

- Minimum supported system: macOS 14.
- Computer Use requires Accessibility and Screen Recording permissions.
- API keys stay in the local credential vault; issue reports must be sanitized before publication.
