# YouTube session, language and audio

YouTube and its Google account routes remain in the originating Chromium profile.
Media stalls and unsupported-codec probes must not move those pages to WebKit,
whose cookie store is independent. Account selection and authentication cookies
remain owned by Chromium and YouTube.

The ordered webpage languages saved in General settings determine Chromium's
native Accept-Language and navigator languages on the next application launch.
The first language also determines the native browser locale. Existing profile
language preferences are refreshed before their request context is initialized.
The application interface language remains independently selectable. Exit location
continues to determine time zone. Explicit site compatibility language rules apply.

YouTube playback prefers the original audio track when the player exposes an
unambiguous original-track marker. Apply this choice once per video, after tracks
are available. Subsequent manual audio choices are retained for that video. If
original-track identity is unavailable, leave the current selection intact.

Acceptance covers Chinese-first and English-first settings, existing persisted
profile language migration, YouTube/Google engine continuity, original-track
selection, manual changes, navigation to another video and unavailable tracks.

CEF is pinned to upstream commit b18cceef8afaf6686147e19a9239f31c2dd81541,
Chromium 156.0.8078.48. Runtime, headers and helper executables must be built from
the same pin with all Astra patches applied. Existing profiles require runtime
smoke and account-switch checks before release.
