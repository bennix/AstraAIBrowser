# Google sign-in popup navigation

X and other sites can use Google Identity Services in a real popup. The popup
must retain the opener and the browser profile's WebKit data store through its
initial `accounts.google.com/gsi/transform` navigation and later redirects.

`SystemMediaPopupHost` owns this WebKit popup. Its navigation delegate must
allow identity-provider main-frame requests through WebKit without canceling
and reloading them to add Astra's optional outward headers. A replacement
`WKWebView.load` creates a separate navigation and may leave the Google popup
blank or prevent the result from reaching the opener. Other popup navigations
may continue to use the existing outward-header policy.

Google account hosts, including regional `accounts.google.*` hosts and their
`/gsi/transform` document, also use native browser fingerprint surfaces. The
document-start privacy wrappers must not alter the identity provider's
challenge, device, or account-selection scripts.

Acceptance: clicking Continue with Google on X opens a rendered Google account
chooser in an Astra-owned popup; returning to X preserves the opener flow.
Canceling the popup leaves X responsive and does not sign in. The same rule
applies to regional Google account hosts and X OAuth callback pages.
Popup provisional-navigation failures and WebKit process exits are logged with
error codes so a remaining blank popup can be diagnosed without logging tokens
or the full login URL.

An existing Chromium tab can reach X through a link or redirect without going
through Astra's explicit navigation method. When its main frame commits an X
URL, the tab must switch to the profile's persistent WebKit view before the
user starts Google sign-in. The Chromium popup must not become the owner of an
X login flow that is configured to use WebKit. Popup URL changes must not
switch the parent tab's engine.

Astra's saved-password control is separate from Google sign-in and passkeys.
It appears only when this origin has a password saved in Astra's own Keychain
store, and its label must describe saved-login filling rather than promise a
specific biometric method. macOS may authenticate with Touch ID or the device
password. A third-party identity popup must not acquire a misleading control.
