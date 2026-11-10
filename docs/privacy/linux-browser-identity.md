# Native browser identity

The user selected native macOS identity after Linux identity continued to
encounter Claude authentication challenges. Chromium now owns its User-Agent,
Client Hints and page and worker platform values. Startup does not install
DevTools identity overrides or a command-line User-Agent override.
WebKit retains its macOS Safari identity. Explicit native HTTP clients use a
macOS Chromium compatibility User-Agent.

Claude uses native fingerprint interfaces across its origin for authentication
compatibility. Encrypted DNS, WebRTC and permission policies are independent.
Actual Cloudflare acceptance requires an interactive verification.
