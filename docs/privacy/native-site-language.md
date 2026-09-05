# Native site language

Mainland Chinese destinations use native Chinese language negotiation before any
automatic translation. The destination policy is owned by CefKit and reused by
the WebKit request adapter.

The policy matches the `.cn` and `.中国` suffixes and a small explicit list of
mainland services using generic domains. Matching is by hostname boundary, not
URL substring or inferred server location. Unknown domains retain the existing
public-egress language policy.

Matching HTTP requests send Chinese-first Accept-Language. The document-start
language override exposes Chinese on matching pages; native security-challenge
surface exceptions still apply.

All webpage translation requires an explicit user action. Page loading, tab
selection, and saved language preferences never start a ZenMux translation.
The previous automatic-display preference is no longer read, including when
older installations saved it as enabled. Explicit webpage and selection
translation remain available, with bilingual display as the manual default.

This does not rewrite a website's account preferences or language cookies.
Sites that prioritize those values may require their own language setting.
The rule cannot guarantee Chinese content when a site does not offer it.

The CefSwift change is reproduced by
`patches/cefswift/prefer-native-chinese.patch`. Run
`node scripts/check_native_site_language.cjs` after applying vendor patches.
