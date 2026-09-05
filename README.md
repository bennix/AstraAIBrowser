# Astra AI Browser

**A native AI browser for macOS.** Astra combines an AppKit-based Mac interface,
a Chromium browsing engine, and an integrated AI workspace.

[Download Astra 1.0 (build 91)](https://github.com/bennix/AstraAIBrowser/releases/download/v1.0.91/Astra-Browser-build91.dmg)
· [Product page](https://bennix.github.io/AstraAIBrowser/)
· [Release notes](https://github.com/bennix/AstraAIBrowser/releases/tag/v1.0.91)

The current release is built for Apple Silicon, signed with an Apple Developer ID,
and accepted by Apple's notarization service.

## Highlights

- Native macOS interface with tabs, spaces, profiles, downloads, and keyboard-first navigation.
- Chromium 151 compatibility through the embedded CEF runtime.
- Legacy `chrome://memory` and `phi://memory` links open Astra's local AI memory instead of Chromium's removed WebUI.
- Local AI memory uses an account-scoped SQLite vector index, renders Markdown tables and LaTeX locally, exports one or several selected entries as Markdown files, remembers completed user/AI turns, and summarizes expired conversation memory before removing its source records.
- Browsing history stays in each persistent Chromium profile; the native History menu, Command-Y, and General settings provide direct access to viewing or clearing it.
- Account settings show whether Astra owns both HTTP and HTTPS and can request complete macOS default-browser ownership.
- Links opened by other macOS apps enter Astra's embedded Chromium tabs. Astra's rendered interface follows the user-selected app language and defaults to Simplified Chinese on a fresh installation, while web-exposed language signals follow the country of the public egress IPv4 address without storing that address.
- Do Not Track is enabled by default, applies to Chromium and WebKit request paths and JavaScript surfaces, and can be changed from General settings.
- Explicit HTTP pages use Astra's existing in-app compatibility engine when the embedded Chromium network stack cannot reach a legacy server, while HTTPS browsing keeps its normal Chromium path.
- Integrated AI workspace for browsing and task assistance.
- A local prompt library saves selected webpage text and sent prompts, then supports task categories, search, reuse, editing, bulk deletion, and portable JSON import or export.
- ZenMux page vision and up to five removable image attachments with thumbnail previews.
- ZenMux can verify current claims with bounded Google and DuckDuckGo search plus public-page fetching, while treating retrieved content as untrusted data and blocking private-network targets.
- ZenMux requires a question, separate object list, explicit accounting basis, time rule, scope and exclusions, and purpose before research begins. It searches short entities before action and responsible-site queries, preserves source terminology and reporting dates, prevents overlapping accounts from being added, and returns an auditable object comparison table behind automated quality gates.
- The AI composer actively lays out wrapped text, keeps its viewport width stable while scrolling, expands for research briefs, and scrolls long drafts without overlapping or flickering lines.
- Paste images directly into ZenMux, or add a removable capture of the exact visible browser viewport from the composer, including the current standard video frame.
- ZenMux answers render GitHub-style Markdown tables and normalize common model-specific LaTeX wrappers before native math rendering.
- YouTube ad playback acceleration: detected ads play at 8× and the previous content speed is restored afterward.
- YouTube video pages expose a native sidebar digest action that uses available captions or audiovisual analysis to produce full-video chapters, evidence, timestamps, and explicit uncertainty through ZenMux.
- X and Twitter pages expose a native bookmark archive action beside the address bar and in the sidebar. Collection runs in the current signed-in tab without opening background tabs, supports pause, resume, and stop, and preserves full visible post details, image references, and link-only video records. The resulting Markdown can stay local or be sent to ZenMux for classification after explicit confirmation.
- Opening About Astra Browser checks the signed GitHub Releases channel for updates; downloads remain protected by Sparkle Ed25519 verification and Apple code signing.
- Website links for installed macOS applications, including Tencent Meeting SSO links, are intercepted before Chromium error handling and opened through Launch Services after explicit confirmation.
- Public web pages expose native bilingual immersive translation with progressive inline writeback, redraw recovery, selected-text translation, a target-language picker, and the configured ZenMux engine.
- Automatic webpage display defaults to Simplified Chinese with English fallback while outward language signals continue to follow the public egress region.
- Repeated tab selections reconcile the visible content surface after rapid switches, loading transitions, or security-page focus handoffs.
- General language settings provide an ordered webpage display language list with add, remove, and priority controls.
- WebKit pages preserve source context for temporary Blob URLs and route Blob-backed card downloads into Astra's native download list.
- Selected text can be translated or looked up from the webpage context menu in one pointer-anchored card that updates in place, supports copying translated text, and saves dictionary results to a persistent Vocabulary Book with Markdown export.
- YouTube and other WebKit media pages support HTML element fullscreen.
- Mainland and H.264/AAC-first video sites use an in-app system media engine when the bundled Chromium codec set is insufficient, while YouTube keeps its Chromium VP9/AV1 path. X uses a persistent system WebKit session for reliable macOS media playback.
- Window close preserves tabs and live page state for the next Dock activation, while a fully closed final window now has a native fallback so Astra cannot remain running without a reopenable interface.
- WebRTC exposes no direct candidates, while camera and microphone access requires one-time approval.
- Silent WebAudio fingerprinting is disrupted at document start: fingerprint readbacks are randomized per page context and zero-gain processing graphs cannot claim the system audio output. Deferred legitimate audio connections are bounded, deduplicated, and restored asynchronously so privacy protection cannot block page navigation. Standard HTML media playback is left unchanged.
- Canvas and WebGL readbacks are farbled per site and session, precise Apple GPU models are masked, protected local and Chinese fonts resist direct and text-metric enumeration, and exposed hardware and language signals are normalized to a coherent profile.
- Authentication and security-challenge routes use Chromium-native Canvas, WebGL, WebAudio, and font surfaces so slider CAPTCHA widgets can load and validate consistently; ordinary pages retain Astra's fingerprint privacy protections.
- Grok stays in its persistent Chromium session after sign-in, and X OAuth popups retain their originating page relationship.
- Chrome Web Store installs remain inside Astra and installed extension actions stay visible on Chromium-rendered pages.
- Newly opened YouTube and other Chromium-heavy tabs stay attached to Astra, and close promptly even if the underlying Chromium window has already disappeared.
- X and Twitter image viewers provide visible zoom-out, 100%–800% slider, zoom-in, percentage, and reset controls, alongside native trackpad pinch, wheel, double-click zoom, and drag-to-pan.
- Selected-text Google searches on X and other WebKit-rendered pages open in a new Astra tab instead of Safari, including selections inside text fields.
- Saved website credentials use an authenticated Keychain context so suggestion selection, Touch ID approval, and form filling complete as one coordinated flow.
- Browser automation traverses accessible same-origin frames, recognizes contenteditable and design-mode rich-text editors, translates nested-frame coordinates, and verifies that entered text persists before reporting success.
- X pages include a native local-first spam shield with whitelist precedence, reversible hiding, one-click Guard blocking with on-pill progress, a six-hour primary-source update check, GitHub mirror fallback, and manual database updates in General settings.
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
