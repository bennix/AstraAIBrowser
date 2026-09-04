# Prompt library

`PromptLibraryStore` owns local prompt documents stored in `PromptLibrary.json`
under the browser data directory. It follows the vocabulary book persistence
pattern. UI state (search, filter, selection and editor) belongs to the sidebar
popover; the store does not own windows or tabs.

Web selection actions in both CEF and WebKit can save the selected text with
its source URL. The chat session archives nonempty user-authored text when it
accepts a send action. An unsuccessful model response does not remove the
archived prompt. Attachments, page context and assistant output are not archived.
Automatic archival deduplicates exact content after trimming outer whitespace,
preserving existing titles and categories.

Insertion appends to the current draft and never initiates sending. Prompts can
be edited, grouped by a free-text task category, searched and batch deleted.

JSON export contains an array of prompt records (id, title, category, content,
optional sourceURL). It exports checked records, or all records when none are
checked. Import validates the entire array before an atomic write, merges by
trimmed content, and assigns new identifiers to avoid replacing unrelated
records. Imports are limited to 10 MB and 10,000 records. An unreadable existing
library blocks writes so corruption cannot silently erase existing data.
