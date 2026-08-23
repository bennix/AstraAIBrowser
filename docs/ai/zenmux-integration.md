# ZenMux AI integration

Astra Browser's native chat uses ZenMux as its only model provider. It does not
fall back to the private Chromium AI extension or to a bundled model.

## Networking and credentials

All ZenMux operations are owned by `Sources/Networking/APIClient.swift`. Text
chat and model discovery use the OpenAI-compatible endpoints under
`https://zenmux.ai/api/v1`. Visual localization uses ZenMux's Vertex-compatible
`generateContent` endpoint because that endpoint accepts screenshot bytes as
`inlineData` without creating a provider-relative temporary `fileUri`.

The API key is stored in an AES-256-GCM encrypted JSON envelope under the
user's Application Support directory. The random encryption key is stored in
the macOS data-protection Keychain and is restricted to the current device.
The JSON file never contains the API key in plaintext.

## Browser context

Regular tabs share their title, URL, and a bounded readable-text extraction
with ZenMux. For YouTube video URLs, Astra also attempts to load the available creator-provided or auto-generated
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

## Browser control

ZenMux chat can request a bounded set of OpenAI-compatible browser tools:
inspect the current page, navigate, click a DOM element, enter non-secret text,
press a safe key, wait for a dynamic element, scroll, go back, reload, or open a
URL in a new tab. The chat session owns the tool-call loop, while
`CefWebContentWrapper` owns DOM inspection and action execution. This preserves
the Chromium integration boundary and keeps network requests in `APIClient`.

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
verification-code, and payment fields reject AI input. Routine controls do not
show repeated confirmation prompts; native confirmation remains for submit
controls. A dispatched action is never treated as proof of completion: Astra
requires two post-action DOM inspections after every state-changing action
before the assistant can provide its final answer. The snapshots are sampled
separately so delayed web-app updates can be detected, and inconsistent states
must be reported as unverified. A single chat request is limited to
thirty-two tool rounds, and the prompt directs the model to stop repeated
unchanged inspections or actions.

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
