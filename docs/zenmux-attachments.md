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

PDF is sent as original bytes using `file.file_data` or Vertex `inlineData`.
Office XML containers are extracted locally before either protocol is encoded:
Word paragraphs, PowerPoint slides and notes, spreadsheet cached cell values
and shared strings, and OpenDocument text. The original filename is retained.
The model receives text, not an unsupported Office MIME type. Images, charts,
layout, macros, and embedded objects are not interpreted. Extracted text is not
the original file and cannot satisfy a request to upload the original document.

The picker recognizes the families above, but legacy binary Office formats,
RTF, encrypted files, and invalid containers currently fail locally with an
export-to-PDF/DOCX/XLSX/PPTX instruction. They are not falsely sent as supported
model input. Raw historical Office attachments produce an explicit unavailable
marker rather than poisoning later requests. Reattach them to extract content.

ZIP reading uses the system unzip executable with arguments, never a shell or
filesystem extraction. Only approved XML member paths are read, with member,
aggregate byte, count, and process-time limits. External XML entities are not
resolved; internal entity declarations are rejected. No Office application is
required or launched.

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
verify extracted PPTX text and absence of unsupported Office inline data in
Vertex requests. This check does not send files to a model.

Protocol reference: <https://zenmux.ai/docs/api/openai/create-chat-completion.html>
