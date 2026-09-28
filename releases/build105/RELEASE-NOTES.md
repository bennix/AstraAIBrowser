## Astra Browser 1.0 (Build 105)

- Run CEF's native macOS event loop as the single owner of browser and AppKit event dispatch.
- Preserve Chromium saved-login suggestion acceptance while keeping address entry and tab switching responsive.
- Route system quit events through CEF's asynchronous browser shutdown lifecycle.
- Keep the application-menu Quit command enabled and route it through the same orderly shutdown path.
- Retain Chromium's native password store and its existing authentication checks.

The Apple Silicon DMG is signed with Developer ID and notarized by Apple.
