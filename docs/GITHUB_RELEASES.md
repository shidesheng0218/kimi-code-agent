# GitHub Release Runbook

Kimi Code Agent is distributed directly from GitHub Releases, not the Mac App Store.

Default distribution uses **ad-hoc signing without Apple notarization**: no
Apple Developer account is required, and any machine can cut a release. Users
bypass Gatekeeper once on first launch (see the README installation section).

## Required GitHub Secret (Sparkle auto-update)

| Secret | Purpose |
| --- | --- |
| `KIMI_SPARKLE_EDDSA_PRIVATE_KEY` | EdDSA (ed25519) private key used by `sign_update` to sign the update ZIP and refresh `appcast.xml`. Lives in the release machine's Keychain (`https://sparkle-project.org` / `ed25519`); losing it blocks future signed updates. |

Without this secret the release still publishes the DMG/ZIP/SHA256SUMS, but
the Sparkle feed is not updated and installed clients will not auto-update.

## Optional GitHub Secrets (Developer ID + notarization)

These are only needed if a future maintainer wants Developer ID signed and
notarized builds. When any of them is missing, the release workflow skips
certificate import and notarization and falls back to ad-hoc signing.

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
3. The **Release macOS** workflow builds the native SwiftUI app for the runner architecture, embeds the headless engine runtime, signs it (ad-hoc by default; Developer ID + notarization only when the optional secrets are configured), validates the DMG/ZIP, and creates a GitHub Release.
4. Verify the published Release contains the DMG, ZIP, and `SHA256SUMS` file.
5. Download the asset on a clean macOS account and confirm: Gatekeeper bypass (right-click → Open, or `xattr -dr com.apple.quarantine` on the app), launch, API setup, a local terminal command, a Browser task, and app restart recovery.

## Sparkle Update Feed

Automatic updates should only be enabled after an EdDSA public key and a signed `appcast.xml` are available. Keep the appcast in a GitHub Pages branch or another HTTPS static host. Do not enable automatic updates against an unsigned feed.

## Support Boundaries

- Minimum supported system: macOS 14.
- Computer Use requires Accessibility and Screen Recording permissions.
- API keys stay in the local credential vault; issue reports must be sanitized before publication.
