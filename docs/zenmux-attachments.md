# Chat attachments

The sidebar composer uses one attachment queue for the file picker, Finder
file drops, clipboard files, pasted images, and visible-page captures. Each
message accepts up to five files. Loading runs off the main thread. Pending
attachments can be removed; sent messages retain their filenames and content.

PDF and the following Office document families are accepted by both the picker
and Finder drag/paste import (extensions are case-insensitive):

- Word: DOC, DOCX, DOCM, DOT, DOTX, DOTM, RTF.
- Excel: XLS, XLSX, XLSM, XLSB, XLT, XLTX, XLTM.
- PowerPoint: PPT, PPTX, PPTM, PPS, PPSX, PPSM, POT, POTX, POTM.
- OpenDocument: ODT, ODS, ODP.

Documents are sent as original bytes with the filename and MIME type.
The OpenAI-compatible route uses `file.file_data`; the Gemini
Vertex route uses `inlineData` and a filename text part. The selected provider
and model must support the document format. This is transport support, not a
local Office parser: encrypted files, unsupported formats, macros, and embedded
objects are not interpreted by the browser. Provider errors remain visible.

Text and source files, including Python, Swift, and C, are decoded as UTF-8 or
BOM-marked UTF-16 and sent as text with a filename. The browser never executes
attached code. File contents are explicitly identified as untrusted data.

Limits are 10 MB per document and 500 KB per normalized text file. Images retain
the existing 50 MB source, 2,048-pixel dimension, and 3 MB encoded limits. Empty,
unsupported, oversized, and undecodable files fail visibly rather than being
silently truncated. Files are sent only when the user sends the message.

Run `node scripts/check_zenmux_attachments.cjs` to check supported extensions,
picker content types, file imports, both protocol encoders, and rejection paths
without starting the CEF XCTest host. Set `ASTRA_ATTACHMENT_FIXTURE` to a local
document path to also check the real file through the Finder pasteboard and
verify byte-for-byte preservation. This check does not send files to a model.

Protocol reference: <https://zenmux.ai/docs/api/openai/create-chat-completion.html>
