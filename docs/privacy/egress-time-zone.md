# Browser time zone and egress location

The browser process owns the time zone exposed by WebKit and Chromium. At
startup, Astra uses a public IPv4 location lookup. The lookup receives the observed exit IP and country in one
response, so rotating exit addresses cannot mismatch two separate lookups.
For countries with a single predictable civil time zone, Astra sets the
browser process `TZ` before initializing CEF or creating a WebKit page. This
browser rule takes priority over the shell or Launch Services `TZ` value.

Countries with multiple time zones and unknown lookup results keep the system
time zone. A country code alone cannot select the correct city-level zone.
Each application startup queries the current exit before creating browser engines.
Changing the proxy exit while Astra is running requires a restart to update
the browser process time zone. Neither this setting nor script-level privacy
controls can alter the router's exit IP, DNS resolver, or TCP fingerprint.

Acceptance: a Japanese exit selected before launch exposes `Asia/Tokyo` and
UTC+09:00 in both browser engines; an unknown or multi-zone country leaves
the host's time zone intact. WebRTC must not disclose a direct local address
that differs from the proxied HTTP exit.

Claude language negotiation uses English (`en-US`, `en`) for claude.ai and
claude.com, including subdomains, independently of the exit country. Both
native request headers and navigator language values follow this rule.
Explicit localized URLs and account language preferences can override negotiation.

International web content defaults to English independently of VPN geography.
The exit-country lookup controls the time zone and adds a regional fallback
language after English and Chinese. Chromium receives the language list
natively so navigation and subresource headers agree with JavaScript. QUIC is disabled to keep HTTPS on the TCP path used by HTTP proxies.

Chromium uses the outward language as its native locale as well as its
Accept-Language preference, keeping Intl defaults aligned without replacing
Intl constructors in page scripts. The native Astra interface has its own locale.

The startup lookup has an eight-second network budget to accommodate proxy
connection setup. A failed lookup is logged explicitly before retaining the
system time zone. Successful isolated smoke tests do not establish the result
of a later normal launch; both paths must be checked.

Malaysia maps to `Asia/Kuala_Lumpur` (UTC+08:00), and Japan maps to
`Asia/Tokyo` (UTC+09:00). Startup does not replace JavaScript Date or Intl.
A selected proxy must not fall back to a direct exit for this lookup.

Language priority is English, Simplified Chinese, then the exit country's
language when it differs from those two. Chromium receives the list through
its native configuration. Existing site-specific compatibility language rules
remain authoritative. The native interface language is independent.

A split-routing proxy may choose different exits for the lookup and destination,
so lookup agreement cannot guarantee agreement for every site.
