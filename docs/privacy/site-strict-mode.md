# Site-specific strict fingerprint protection

Normal browsing remains the default. Strict protection is enabled initially
for the exact host `claude.ai`; users can opt other hosts in or out through
the address bar's Site Settings menu. Preferences use exact normalized host
names, not suffix matching, and never match lookalike domains.

FingerprintPrivacyPolicy owns the persisted host list. The browser captures
the list once at launch and installs the same script in Chromium and WebKit
before page scripts run. Changes require an app restart; the menu distinguishes
saved preferences from the active launch snapshot. This avoids claiming that
late injection can undo data already read by a page.

Strict protection denies canvas pixel export, WebGL pixel readback and debug
renderer data, WebGPU adapter acquisition, offline audio rendering, audio analysis,
and local font queries. WebGPU-based applications require disabling strict mode
for that site. Worker contexts and HTTP Client Hints are not fully covered by
these document-script restrictions.
Ordinary rendering, network requests and JavaScript continue to run. Known
authentication/challenge documents retain the existing compatibility exception.
This can affect image editors and audio tools and does not hide prompts,
account identity, exit IP, or the existence of privacy protection from a site.

Acceptance: normal and lookalike hosts retain the normal policy; a selected
host gets no raw data from protected reads; auth documents retain native APIs;
turning the preference off takes effect after restarting the app. Opening the
menu displays the saved state and whether a restart is pending.

Claude navigation stays in Chromium, including login and marketing pages.
Media compatibility fallback must not replace its browser engine or cookie
store while an authentication or security verification flow is running.

Chromium receives a native reduced User-Agent override with the engine's major
version and zeroed minor/build/patch components. The native override suppresses
high-entropy Client Hints values in request headers as well as script APIs.
Low-entropy platform and major-version hints remain available. This is verified
against actual requests after a server sends Accept-CH.

Client Hints use the native reduced User-Agent policy. Document scripts must
leave NavigatorUAData.getHighEntropyValues intact to preserve its Promise
contract for verification clients. Cloudflare challenge documents under the
exact /cdn-cgi/challenge-platform path prefix retain native browser surfaces.
Ordinary documents retain their selected privacy policy. This compatibility
exception does not automate verification or guarantee acceptance by a site.

Do Not Track wrappers preserve an existing native getter when its value already
matches the preference. The compatibility fallback is installed only when the
engine value differs. This avoids exposing redundant API replacements.

Normal pages now retain native navigator, Canvas, WebGL, audio and font interfaces.
The launch-snapshot host list gates all JavaScript fingerprint protection before
any interface is replaced. Selected hosts and their embedded frames receive the
existing strict policy, with authentication compatibility exceptions preserved.
Native locale, User-Agent, WebRTC and permission controls remain independent.

## Claude authentication compatibility

Claude origins claude.ai and www.claude.ai use native fingerprint interfaces
throughout the origin, including landing pages and client-side login navigation.
This compatibility exception takes precedence over saved strict-site selection.
It prevents immutable script wrappers from persisting into authentication.
Native permissions, WebRTC policy and encrypted DNS retain their own controls.
Websites can read native browser capabilities under this exception.
Acceptance checks native surfaces before and after login navigation, exact host
matching, and the actual Claude authentication page in the test application.
