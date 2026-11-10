# Automatic browser proxy

The General settings page owns the user's proxy mode. The default remains the browser's existing system behavior. When automatic proxy detection is enabled, Astra first follows an active macOS system proxy. If macOS has none, Astra may use a verified local HTTP CONNECT proxy on loopback. Detection must never change macOS or another application's network settings.

The browser networking layer owns the effective proxy configuration. The UI displays the detected source, endpoint, and whether a restart is needed; it does not probe or configure network stacks directly. WebKit and Chromium must receive the same selected endpoint. When a local proxy is selected, each engine must be allowed to fall back to direct access if that proxy fails for a request. Removing the saved endpoint must also clear WebKit's custom proxy configuration on its shared data store. A missing or failed candidate leaves the existing system behavior in place. Detection must not log proxy credentials or page content.

The setting is reversible and defaults off. Disabling it restores the browser's existing system behavior after an Astra restart. Both browser engines read the saved result when creating their network stack, so enabling, disabling, or refreshing the selection requires a restart to apply to every tab. With no system proxy, a verified local HTTPS proxy is selected with direct fallback for requests it cannot serve. If the local proxy probe fails, Astra uses direct access when available. The local candidate is `127.0.0.1:7890` and must answer an HTTP CONNECT request before it is saved and again before a saved choice is applied at the next launch. A TCP listener alone is insufficient evidence that the proxy can serve HTTPS. At startup, a closed or unhealthy local proxy is ignored and its saved endpoint is cleared. A local proxy disappearing after startup must not silently change the operating system proxy or delete login state.

Acceptance: with macOS system proxy enabled, report and use it; with system proxy disabled and a healthy local HTTP CONNECT proxy, use it with direct failover; with an unhealthy local proxy and working direct HTTPS, use direct access even if the proxy port listens; with neither route healthy, report the failure. A saved local endpoint must be cleared when the proxy probe fails. The UI must distinguish a working direct connection from a failed proxy probe and indicate when a restart is needed to replace an already running network stack. X Chat, YouTube, and Claude must be tested separately in the running browser; a successful probe is not evidence that every page works.

## Required privacy proxy

An explicit privacy mode takes precedence over automatic detection and system
proxy settings. It uses a dedicated loopback HTTP CONNECT listener at
127.0.0.1:7891, configured to send every destination through the selected
outbound proxy. Both browser engines must fail closed if that listener is
unavailable, including at startup. Turning this mode off restores the existing
automatic/system policy after restart. The UI explains the required listener
and restart. The application never reconfigures the VPN itself.

Acceptance: privacy mode chooses the dedicated endpoint even with automatic
detection off or the listener stopped. Chromium omits direct fallback and
WebKit sets allowFailover to false. Automatic mode retains its existing behavior.

Startup country lookup uses the same selected local proxy as Chromium. Required
mode prohibits direct fallback for this lookup too. A failed lookup leaves the
country unknown rather than querying through another route.
