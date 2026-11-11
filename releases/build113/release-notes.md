## Browser engine and YouTube

- Upgrade to Chromium 156.0.8078.48 / CEF 156.0.14 with matching runtime, headers and helpers.
- Keep YouTube and Google account flows in Chromium when media stalls or codec checks fail, avoiding a switch into a separate WebKit cookie store.
- Apply the ordered webpage languages from General settings to native Chromium headers and navigator languages after restart. Migrate existing profile language preferences.
- Prefer positively identified original YouTube audio once per video, retaining subsequent manual track choices. Unidentified tracks keep the site selection.
- Retain media URL discovery, HLS fragment download and merging, live recording, progress and persistent download history.

## Verification and installation

40 regression tests passed, with additional original-audio script checks. Chromium runtime checks confirmed matching Chinese-first and English-first request headers and navigator languages. Real multi-account YouTube switching has not yet been independently verified after Google sign-in.

Developer ID-signed, Apple-notarized DMG for Apple Silicon, macOS 14 or later. Open the DMG and drag Astra Browser into Applications.

Manual installation is required. The signed Sparkle update feed remains at Build 106 because the matching update signing key is unavailable.
