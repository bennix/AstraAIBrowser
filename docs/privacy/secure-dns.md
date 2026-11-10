# Secure DNS

Astra owns an enabled-by-default Secure DNS preference in browser settings.
At startup it merges Chromium Local State DNS-over-HTTPS preferences before
CEF initializes. Enabled mode uses Cloudflare HTTPS DNS in secure mode, which
has no plaintext DNS fallback. Disabling selects the platform resolver.
Existing unrelated Local State entries must survive either transition.
Malformed Local State must produce an error without overwriting the file.

Settings apply after restarting Astra. WebKit compatibility pages and remote
HTTP proxy resolution are outside this Chromium preference. The settings
explain this scope. DNS queries delegated to an HTTP proxy remain controlled
by that proxy; this setting cannot force a proxy's upstream resolver or location.

Acceptance covers enable, disable, preserving unrelated state, malformed input,
and the rendered settings control. Runtime DNS leak verification requires a
completed browser DNS test and must identify the actual proxy route.
