# ZenMux AI integration

Astra Browser's native chat uses ZenMux as its only model provider. It does not
fall back to the private Chromium AI extension or to a bundled model.

## Networking and credentials

All ZenMux operations are owned by `Sources/Networking/APIClient.swift`. Text
chat and model discovery use the OpenAI-compatible endpoints under
`https://zenmux.ai/api/v1`. Visual localization and Gemini-backed immersive
translation use ZenMux's Vertex-compatible `generateContent` endpoint. The
visual path accepts screenshot bytes as `inlineData` without creating a
provider-relative temporary `fileUri`; translation sends bounded text segments
and disables browser tools.

The API key is stored in an AES-256-GCM encrypted JSON envelope under the
user's Application Support directory. The random encryption key is stored in
the macOS data-protection Keychain and is restricted to the current device.
The JSON file never contains the API key in plaintext.

## Browser context

Regular tabs share their title, URL, and a bounded readable-text extraction
with ZenMux. The composer can capture the visible CEF viewport through the
existing browser automation boundary and prepare it with the same bounded image
pipeline used by pasted and selected files. The user sees a removable thumbnail
before the capture is sent. Each request also includes the client-supplied local
and UTC date so the model cannot treat today's calendar date as a future event.
When the user asks whether a claim is true or current, ZenMux can call
`web_search`, `fetch_url`, and `general_research`. `web_search` opens Google Search in a new tab in
this browser (the same destination as Search with Google), reads the first three
result pages from that tab, and supplements those hits with a DuckDuckGo HTML
search in `APIClient`. It does not replace the current tab. `fetch_url` stays in
`APIClient`, rejects private-network targets, and returns untrusted text. For YouTube video URLs, Astra also attempts to load the available creator-provided or auto-generated
captions and includes timestamped caption text in the model context. Caption
text is marked as untrusted page data so it cannot override system
instructions. Each conversation caches the result by URL and input-language
preference, and caption context is limited to 50,000 characters.

Caption loading uses the MIT-licensed `YouTubeTranscript` product from
`arraypress/swift-youtube-metadata`, pinned to version 0.1.0. The package uses
YouTube's undocumented InnerTube interface. Failures are expected when YouTube
changes that interface, disables captions, rate-limits the client, or requires
additional verification. Caption failure never blocks ZenMux chat and never
activates another AI provider.

YouTube video pages expose a contextual digest action in the native sidebar.
The action opens the existing chat session with an evidence-aware digest prompt
and immediately sends when a ZenMux credential is available. It reuses the same
caption context and audiovisual fallback as normal page-aware chat, so it does
not add another video downloader, model provider, credential store, or network
owner.

## Immersive translation

Public HTTP and HTTPS pages expose a native immersive-translation control in
the sidebar. `CefWebContentWrapper` extracts a bounded set of visible readable
segments, preserves the original DOM, and inserts removable translated blocks
directly after their source elements. A page URL change invalidates the per-tab
translation state so stale results cannot be applied to a different document.

On macOS 26 or later, users can choose Apple's on-device Translation framework
when the selected language pair is installed and supported. ZenMux-enhanced
translation is available through the existing API credential and networking
boundary. Text is batched with stable segment identifiers, treated as untrusted
webpage data, and sent without browser tools; responses must preserve the exact
identifier order before any translated text is applied.

## Answer rendering

ZenMux answers are normalized before native SwiftUI and SwiftMath rendering.
The block parser supports GitHub-style Markdown tables with escaped pipe
characters and presents wide tables in a horizontal scroller. Common model
formula wrappers, including display fences and equation or alignment
environments, are converted to the supported SwiftMath form. Unsupported
formula fragments fall back to readable normalized source instead of exposing
raw display delimiters.

## Browser control

ZenMux chat can request a bounded set of OpenAI-compatible browser tools:
inspect the current page, navigate, click a DOM element, enter non-secret text,
press a safe key, wait for a dynamic element, scroll, go back, reload, or open a
URL in a new tab. It can also request three grounding tools: `web_search`,
`fetch_url`, and `general_research`. The chat session owns the tool-call loop. `BrowserState` opens
Google Search in a new Chromium tab for `web_search` (three result pages),
`CefWebContentWrapper` owns SERP extraction plus DOM inspection and action
execution, and `APIClient` owns the DuckDuckGo supplement and public page fetch.
This preserves the Chromium integration boundary and keeps HTTP search/fetch in
`APIClient`.

`general_research` requires a six-item task card: one question, a separate
object list, an accounting basis, a bounded or unrestricted time rule, scope
and exclusions, and a purpose. The model also supplies three to eight short
entity terms. It searches entities before entity-plus-action and responsible-
site queries, uses official and primary sources before independent reporting,
and leaves TikTok, full-site Reddit or Hacker News searches, and unofficial
social reposts disabled unless the user explicitly requests them. Topic
modules enable specialist sources such as GitHub, Hugging Face, arXiv,
government and disclosure sites, X, or Polymarket only when relevant.

Search results are opened to verify their date, object, exact accounting term,
overlap, and document type instead of treating snippets as evidence. The
evidence contract keeps one account per object, prevents a subset from being
added to its parent, preserves distinctions among flows, stocks, assets,
equity, income, and balances, and never strengthens an official
characterization. Reports separate confirmed facts from lower-tier
observations, retain three distinct zero-result states, record uncovered sites,
and include a comparison table with object, accounting basis, as-of date,
value, overlap, and source URL. Product or technical object states use
announced, artifact, runnable, replicated, or unverified; policies use a
policy-appropriate state family, and statistical values are never labeled as
artifacts.

A concise user task can follow this form:

```text
Run the general research protocol.
Question: {one sentence}
Objects: {A}, {B}, {C}
Time: {unlimited or START-END plus time zone}
Purpose: {understand, verify, decide, content, or business}
Scope: {optional}
Exclusions: {required}
First map which objects overlap and whether they may be added.
Search short entities before site-constrained responsible-authority queries.
Use only the enabled framework source map for L1 evidence.
Do not strengthen the source's official characterization.
```

Page inspection returns sanitized element HTML, accessibility state, a CSS
selector, a stable per-node reference, and a compatibility numeric index for
visible interactive elements. Actions prefer the stable reference and can fall
back to the selector when a dynamic site replaces the original node. DOM
targets are converted to viewport coordinates and clicked with native CEF mouse
events so applications that ignore synthetic JavaScript clicks still receive a
normal pointer interaction. The wait
tool polls for a visible ref or selector for at most eight seconds. Selectors are
encoded as JavaScript string data; the model cannot submit arbitrary JavaScript.
Serialized HTML omits field values, inline event handlers, `srcdoc`, and Astra's
internal targeting attributes.

When the DOM does not expose a requested target, Astra provides a vision-driven
fallback based on the interaction model used by the MIT-licensed
[Midscene.js](https://github.com/web-infra-dev/midscene) project. Astra captures
only the visible CEF page viewport, compresses it to a bounded JPEG, and sends
it to the selected ZenMux model through the Vertex-compatible `inlineData`
request format. The model returns coordinates in a normalized 0–1000 space, and CEF performs a
native mouse click after converting them to the current viewport size. DOM
references remain the primary path; visual inspection is reserved for canvas,
custom controls, and cross-origin content that structured inspection cannot
reach.

Astra does not embed the Midscene Node runtime. Midscene 1.x requires a modern
Node.js process and performs its own model networking, which would duplicate
the app runtime and violate Astra's centralized networking boundary. Keeping
the vision fallback native avoids an external Node installation, keeps the
ZenMux credential inside the existing credential path, and preserves the
signed app's current lifecycle model.

Page content remains untrusted context and cannot authorize tool use. Password,
verification-code, and payment fields reject AI input. Search snippets and fetched
pages are wrapped as untrusted data in the same way. Routine controls do not
show repeated confirmation prompts; native confirmation remains for submit
controls. A dispatched action is never treated as proof of completion: Astra
requires two post-action DOM inspections after every state-changing action
before the assistant can provide its final answer. The snapshots are sampled
separately so delayed web-app updates can be detected, and inconsistent states
must be reported as unverified. A single chat request is limited to three web
searches, two page fetches, and thirty-two tool rounds, and the prompt directs
the model to stop repeated unchanged inspections or actions.

## Website passwords and Touch ID

Website passwords are separate from ZenMux credentials and browser automation.
On an HTTPS login form, the user can choose to save a submitted username and
password in macOS Keychain. Each saved item is device-bound and protected by
Keychain user-presence access control. Filling a password therefore requires
Touch ID when available, with the Mac login password as the system fallback.

The credential bridge returns only an acknowledgement to the page. After
successful system authentication, native code fills the selected credential
into the matching login fields. As with any password manager, the destination
site can read a password after it is filled into that site's form, but Astra
never adds it to readable page context or sends it to ZenMux. Credential storage
is disabled in incognito profiles. AI browser automation continues to reject
password and verification-code fields, including Google sign-in pages.
