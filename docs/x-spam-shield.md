# Native X Spam Shield

Astra routes X and Twitter pages through the persistent system WebKit engine.
This gives those pages the media codecs provided by macOS and removes the need
for a Chromium extension or a separate player overlay.

## Ownership

- `SystemMediaCompatibilityPolicy` owns the X/Twitter engine route.
- `XSpamShieldWebPolicy` owns passive DOM observation, the isolated Guard pill,
  junk-account badge, and user-initiated X blocking inside X pages.
- `XSpamShieldStore` owns local matching, the six-hour cache, whitelist
  precedence, and the user's locally hidden handle set.
- `APIClient` owns all requests to the upstream public-list service.

The page sends only visible public handles to native code. Native matching does
not send those handles, page content, matches, or local actions over the
network. Clicking Guard, or Block on a junk-account badge, blocks that account
with the signed-in X account through the page session, shows `done/total`
progress on the Guard pill, then hides those posts. Local Hide is no longer the
primary action.

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

Blocking is opt-in: it starts only when the user clicks Guard or Block. Requests
run sequentially with a short delay so X rate limits are less likely to trip.
If the page has no X session, the UI shows a sign-in toast instead of sending
block requests.
# Custom content rules

The Guard gear opens General Settings. Users can add, disable, or delete up to
50 case-insensitive keywords or restricted regular expressions. Rules persist
in the existing shield store. Matching posts stay visible with a badge and join
the existing one-click block queue. Saving or matching a rule never blocks an
account automatically. The signed-in user's own posts are excluded.

ZenMux receives only the user's rule description through APIClient and returns
a draft pattern. The configured model is used. Validation and an explicit Add
rule action are required; generated text is never executed as JavaScript.

Patterns are limited to 256 UTF-8 bytes, without groups, alternation, braces,
backreferences, or more than one repetition operator. Regex matching uses a
progress-cancellation deadline and bounded post text. Rules are checked again
during timeline scans, including a five-second refresh for settings changes.
Guard's own DOM mutations do not retrigger scanning. HTTP 403 is a block failure,
not proof of success.

Run `node scripts/check_guard_rules.cjs` for matcher and injected-script checks.
