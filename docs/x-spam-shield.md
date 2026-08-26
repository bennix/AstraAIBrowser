# Native X Spam Shield

Astra routes X and Twitter pages through the persistent system WebKit engine.
This gives those pages the media codecs provided by macOS and removes the need
for a Chromium extension or a separate player overlay.

## Ownership

- `SystemMediaCompatibilityPolicy` owns the X/Twitter engine route.
- `XSpamShieldWebPolicy` owns passive DOM observation and the isolated badge,
  hide, and undo surfaces inside X pages.
- `XSpamShieldStore` owns local matching, the six-hour cache, whitelist
  precedence, and the user's locally hidden handle set.
- `APIClient` owns all requests to the upstream public-list service.

The page sends only visible public handles to native code. Native matching does
not send those handles, page content, matches, or local actions over the
network. Local hiding changes presentation only and does not call X APIs.

## Public-list integration

The behavior is a clean-room implementation inspired by the local-first design
documented by [Make X Great Again](https://github.com/foru17/make-x-great-again).
Astra does not copy or compile that project's AGPL source code. It retrieves the
published filtering database and whitelist from the upstream primary site at
runtime and keeps the last valid snapshot in the app cache. If the primary site
is unavailable or a payload fails validation, Astra falls back to the pinned
revision in the project's GitHub `data-mirror` branch. The settings pane can
trigger the same update flow on demand and reports which source supplied the
installed snapshot. The upstream project remains the source of the list,
governance, audit trail, and appeals.

The current implementation intentionally supports only passive matching and
reversible local hiding. Native X mute or block actions are excluded because
they mutate the user's account, invoke X automation controls, and require a
separate consent and rate-limiting design.
