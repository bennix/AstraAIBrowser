# Browser search provider

Astra owns one browser search provider preference, shared by the address bar and the native new-tab Search mode. The General settings page provides Google, Baidu, Bing, and DuckDuckGo. Google remains the default for existing installations. The selected provider changes only search queries; recognized URLs and explicit AI input keep their existing behavior.

`URLProcessor` owns query-to-URL conversion and percent encoding. Both the address bar and native new-tab Search mode use this one conversion path. The preference is stored in user defaults, and a new selection applies to the next submitted query without a browser restart. The settings UI only edits and displays the preference.

Acceptance: a query containing spaces and non-ASCII text produces an encoded URL for the selected provider; a URL remains a URL; every provider can be selected in settings and used from the new-tab Search mode and ordinary address-bar fallback.

New-tab Search mode routes URL-shaped input through the existing URL submission
path. Ordinary words continue to use the selected search provider.
