# Astra AI Browser

**A native AI browser for macOS.** Astra combines an AppKit-based Mac interface,
a Chromium browsing engine, and an integrated AI workspace.

[Download Astra 1.0 (build 30)](https://github.com/bennix/AstraAIBrowser/releases/download/v1.0.30/Astra-Browser-build30.dmg)
· [Product page](https://bennix.github.io/AstraAIBrowser/)
· [Release notes](https://github.com/bennix/AstraAIBrowser/releases/tag/v1.0.30)

The current release is built for Apple Silicon, signed with an Apple Developer ID,
and accepted by Apple's notarization service.

## Highlights

- Native macOS interface with tabs, spaces, profiles, downloads, and keyboard-first navigation.
- Chromium compatibility through the embedded CEF runtime.
- Integrated AI workspace for browsing and task assistance.
- ZenMux page vision and up to five removable image attachments with thumbnail previews.
- Paste images directly into ZenMux, or add a removable capture of the exact visible browser viewport from the composer, including the current standard video frame.
- ZenMux answers render GitHub-style Markdown tables and normalize common model-specific LaTeX wrappers before native math rendering.
- YouTube ad playback acceleration: detected ads play at 8× and the previous content speed is restored afterward.
- YouTube and other WebKit media pages support HTML element fullscreen.
- Mainland and H.264/AAC-first video sites use an in-app system media engine when the bundled Chromium codec set is insufficient, while YouTube keeps its Chromium VP9/AV1 path.
- Red-button window close preserves tabs and live page state for the next Dock activation.
- WebRTC exposes no direct candidates, while camera and microphone access requires one-time approval.
- Silent WebAudio fingerprinting is disrupted at document start: fingerprint readbacks are randomized per page context and zero-gain processing graphs cannot claim the system audio output. Standard HTML media playback is left unchanged.
- Grok stays in its persistent Chromium session after sign-in, and X OAuth popups retain their originating page relationship.
- Astra's icon and installation identity remain stable across restarts; the legacy Phi updater cannot replace the installed app.
- Google website sign-in remains available without associating the account with Astra at the browser level or enabling browser sync.
- Local-first controls for browser profiles, credentials, and AI configuration.

## Install

1. Download the notarized DMG from the link above.
2. Open the DMG and drag **Astra Browser** to **Applications**.
3. Launch Astra Browser from Applications.

Requirements: Apple Silicon Mac running macOS 14 or later.

## Build from source

The CEF distribution is intentionally not stored in Git. Prepare the compatible
CEF runtime under `Vendor/CefSwift`, run
`scripts/apply_cef_swift_patches.sh Vendor/CefSwift`, open `Phi.xcodeproj`, and
build the `PhiBrowser-release` scheme with Xcode 26 or later.

Release helpers are available in `scripts/bundle_cef_runtime.sh` and
`scripts/notarize_dmg.sh`. Apple notarization requires your own Developer ID
certificate and notarytool keychain profile.

## Project origin and license

Astra is based on the open-source Phi Browser macOS client. Astra's builds are
independently maintained by this repository and are not official Phi Browser
releases.

The source is available under the Apache License 2.0. See [LICENSE](LICENSE).
Third-party components retain their respective licenses.
