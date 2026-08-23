# Astra AI Browser

**A native AI browser for macOS.** Astra combines an AppKit-based Mac interface,
a Chromium browsing engine, and an integrated AI workspace.

[Download Astra 1.0 (build 12)](https://github.com/bennix/AstraAIBrowser/releases/download/v1.0.12/Astra-Browser-build12.dmg)
· [Product page](https://bennix.github.io/AstraAIBrowser/)
· [Release notes](https://github.com/bennix/AstraAIBrowser/releases/tag/v1.0.12)

The current release is built for Apple Silicon, signed with an Apple Developer ID,
and accepted by Apple's notarization service.

## Highlights

- Native macOS interface with tabs, spaces, profiles, downloads, and keyboard-first navigation.
- Chromium compatibility through the embedded CEF runtime.
- Integrated AI workspace for browsing and task assistance.
- YouTube ad playback acceleration: detected ads play at 8× and the previous content speed is restored afterward.
- Local-first controls for browser profiles, credentials, and AI configuration.

## Install

1. Download the notarized DMG from the link above.
2. Open the DMG and drag **Astra Browser** to **Applications**.
3. Launch Astra Browser from Applications.

Requirements: Apple Silicon Mac running macOS 14 or later.

## Build from source

The CEF distribution is intentionally not stored in Git. Prepare the compatible
CEF runtime under `Vendor/CefSwift`, open `Phi.xcodeproj`, and build the
`PhiBrowser-release` scheme with Xcode 26 or later.

Release helpers are available in `scripts/bundle_cef_runtime.sh` and
`scripts/notarize_dmg.sh`. Apple notarization requires your own Developer ID
certificate and notarytool keychain profile.

## Project origin and license

Astra is based on the open-source Phi Browser macOS client. Astra's builds are
independently maintained by this repository and are not official Phi Browser
releases.

The source is available under the Apache License 2.0. See [LICENSE](LICENSE).
Third-party components retain their respective licenses.
