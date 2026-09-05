// Run the production attachment loader and encoding without the CEF test host.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.join(__dirname, '..');
const chat = fs.readFileSync(path.join(root, 'Sources/UserInterface/Chat/EmbeddedChatViewController.swift'), 'utf8');
const api = fs.readFileSync(path.join(root, 'Sources/Networking/APIClient.swift'), 'utf8');
function between(source, start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first + start.length);
  if (first < 0 || last <= first) throw new Error(`Missing production boundary: ${start}`);
  return source.slice(first, last);
}
const production = [
  between(api, 'struct ZenMuxToolCall:', 'struct ZenMuxChatContentPart:'),
  between(api, 'struct ZenMuxChatContentPart:', 'enum ZenMuxChatRequestContent:'),
  between(api, 'enum ZenMuxChatRequestContent:', 'struct ZenMuxChatRequestMessage:'),
  between(api, 'private enum ZenMuxJSONValue:', 'private struct ZenMuxVertexChatRequest:'),
  between(api, 'enum ZenMuxAPIError:', '/// Stores the ZenMux API key'),
  'private enum ZenMuxVertexChatRequest {\n' + between(
    api.slice(api.indexOf('private struct ZenMuxVertexChatRequest:')),
    '    struct Part: Encodable', '    struct Tool: Encodable'
  ) + '\n}',
  'private enum VertexProbe {\n' + between(api,
    '    private static func vertexParts(', '    static func zenMuxToolNames('
  ) + '\n static func encode(_ part: ZenMuxChatContentPart) throws -> Data {\n' +
    ' try JSONEncoder().encode(vertexParts(from: .parts([part])))\n }\n}',
  between(chat, 'struct ZenMuxAttachment:', 'enum ZenMuxChatVisionContext'),
  between(chat, 'enum ZenMuxAttachmentError:', 'struct ZenMuxChatMessage:'),
].join('\n');
const checks = String.raw`
func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
func rejects(_ url: URL) -> Bool {
    do { _ = try ZenMuxAttachment.load(from: url); return false }
    catch { return true }
}
let source = "print(\"sample\")\n"
func officeFixture(_ ext: String, _ members: [String: String]) throws -> URL {
    let folder = directory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, xml) in members {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }
    let url = directory.appendingPathComponent(UUID().uuidString + "." + ext)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = folder
    zip.arguments = ["-qr", url.path, "."]
    try zip.run(); zip.waitUntilExit()
    check(zip.terminationStatus == 0, "Fixture ZIP failed")
    return url
}
let docx = try officeFixture("docx", ["word/document.xml": "<w:document xmlns:w='urn:w'><w:p><w:r><w:t>Document words</w:t></w:r></w:p></w:document>"])
check(try ZenMuxAttachment.load(from: docx).requestPart.text!.contains("Document words"), "DOCX text missing")
let xlsx = try officeFixture("xlsx", [
    "xl/sharedStrings.xml": "<sst><si><t>Revenue</t></si></sst>",
    "xl/worksheets/sheet1.xml": "<worksheet><row><c r='A1' t='s'><v>0</v></c><c r='B1'><v>42</v></c></row></worksheet>"
])
let sheetText = try ZenMuxAttachment.load(from: xlsx).requestPart.text!
check(sheetText.contains("A1: Revenue") && sheetText.contains("B1: 42"), "Shared strings/cell references missing")
let malicious = try officeFixture("pptx", ["ppt/slides/slide1.xml": "<!DOCTYPE x [<!ENTITY secret 'injected'>]><x>&secret;</x>"])
check(rejects(malicious), "XML entities accepted")
let emptyOffice = try officeFixture("docx", ["word/document.xml": "<document/>"])
check(rejects(emptyOffice), "Empty Office text accepted")
let requiredFormats = [
    "pdf", "doc", "docx", "docm", "dot", "dotx", "dotm", "rtf",
    "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm",
    "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm",
    "odt", "ods", "odp"
]
for ext in requiredFormats {
    let url = directory.appendingPathComponent("file.\(ext.uppercased())")
    check(ZenMuxAttachment.supports(url), "Missing Office/PDF format: \(ext)")
    check(ZenMuxAttachment.allowedContentTypes.contains { $0 == UTType(filenameExtension: ext) }, "Picker excluded \(ext)")
}
if let path = ProcessInfo.processInfo.environment["ASTRA_ATTACHMENT_FIXTURE"] {
    let url = URL(fileURLWithPath: path)
    let attachment = try ZenMuxAttachment.load(from: url)
    check(attachment.mimeType == "text/plain", "Office document was not normalized to text")
    check(attachment.filename == url.lastPathComponent, "Real document name changed")
    check(attachment.requestPart.type == "text", "Office document sent as unsupported native file")
    check(attachment.requestPart.text!.contains("Python"), "Supplied PPTX text was not extracted")
    let vertex = try JSONSerialization.jsonObject(with: VertexProbe.encode(attachment.requestPart)) as! [[String: Any]]
    check(vertex[0]["text"] as? String == attachment.requestPart.text, "Extracted text lost in Vertex conversion")
    check(vertex[0]["inlineData"] == nil, "Office MIME leaked to Vertex")
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    check(pasteboard.writeObjects([url as NSURL]), "Real document drag pasteboard")
    let sources = ZenMuxAttachmentPasteboardReader.sources(from: pasteboard)
    check(sources.count == 1, "Real document drag not recognized")
    let dropped = try sources[0].load()
    check(dropped.data == attachment.data, "Drop extraction differs from file picker")
    print("PASS: supplied PPTX extracted into model-readable text through picker and Finder (\(attachment.data.count) bytes)")
}
for ext in ["py", "swift", "c", "csv", "md", "json"] {
    let url = directory.appendingPathComponent("sample.\(ext)")
    try source.write(to: url, atomically: true, encoding: .utf8)
    let file = try ZenMuxAttachment.load(from: url)
    check(!file.isImage && file.requestPart.type == "text", "Source must be text")
    check(String(data: file.data, encoding: .utf8) == source, "Source content changed")
    check(file.requestPart.text!.contains(url.lastPathComponent), "Filename lost")
}
let utf16 = directory.appendingPathComponent("unicode.txt")
try "Unicode: café".write(to: utf16, atomically: true, encoding: .utf16)
let decoded = try ZenMuxAttachment.load(from: utf16)
check(String(data: decoded.data, encoding: .utf8) == "Unicode: café", "UTF-16 decoding")
for (ext, mime) in ZenMuxAttachment.documentMIMETypes {
    let url = directory.appendingPathComponent("report.\(ext)")
    let bytes = Data("transport fixture".utf8)
    try bytes.write(to: url)
    if ext != "pdf" {
        check(rejects(url), "Invalid Office container accepted")
        let historical = ZenMuxAttachment(filename: url.lastPathComponent, mimeType: mime, data: bytes)
        check(historical.requestPart.type == "text", "Raw Office history poisoned the request")
        continue
    }
    let attachment = try ZenMuxAttachment.load(from: url)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment.requestPart)) as! [String: Any]
    let file = object["file"] as! [String: Any]
    check(object["type"] as? String == "file", "Wrong document part")
    check(file["filename"] as? String == url.lastPathComponent, "Document filename lost")
    check(file["file_data"] as? String == "data:\(mime);base64,\(bytes.base64EncodedString())", "Document bytes changed")
    check(object["image_url"] == nil, "Document sent as image")
    let vertex = try JSONSerialization.jsonObject(with: VertexProbe.encode(attachment.requestPart)) as! [[String: Any]]
    let inline = vertex[1]["inlineData"] as! [String: Any]
    check(vertex[0]["text"] as? String == "Attached file: \(url.lastPathComponent)", "Vertex filename lost")
    check(inline["mimeType"] as? String == mime, "Vertex document MIME lost")
    check(inline["data"] as? String == bytes.base64EncodedString(), "Vertex document bytes lost")
}
let invalid = directory.appendingPathComponent("invalid.py")
try Data([0, 255, 128]).write(to: invalid)
check(rejects(invalid), "Binary source accepted")
let oversized = directory.appendingPathComponent("large.txt")
try Data(repeating: 65, count: ZenMuxAttachment.maximumTextBytes + 1).write(to: oversized)
check(rejects(oversized), "Oversized text accepted")
let empty = directory.appendingPathComponent("empty.pdf")
try Data().write(to: empty)
check(rejects(empty), "Empty document accepted")
let unsupported = directory.appendingPathComponent("program.exe")
try Data([1, 2, 3]).write(to: unsupported)
check(rejects(unsupported), "Unsupported file accepted")
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
let urls = ["report.pdf", "report.xls", "report.xlsx", "report.docx", "sample.swift"].map {
    directory.appendingPathComponent($0)
}
check(pasteboard.writeObjects(urls.map { $0 as NSURL }), "Write drag pasteboard")
check(ZenMuxAttachmentPasteboardReader.fileURLs(from: pasteboard) == urls, "Multi-file drop lost URLs")
let sources = ZenMuxAttachmentPasteboardReader.sources(from: pasteboard)
check(sources.count == 5, "Multi-file paste lost files")
pasteboard.clearContents()
pasteboard.setString("ordinary text", forType: .string)
check(ZenMuxAttachmentPasteboardReader.sources(from: pasteboard).isEmpty, "Text paste intercepted")
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9YP8b1sAAAAASUVORK5CYII=")!
let image = try ZenMuxAttachment.prepare(data: png, filename: "image.png")
check(image.isImage && image.requestPart.type == "image_url", "Image regression")
print("PASS: file loading, text encoding, both document protocols, limits, Finder pasteboard, and images")
`;
const result = spawnSync('swift', ['-'], {
  input: 'import Cocoa\nimport ImageIO\nimport UniformTypeIdentifiers\n' + production + checks,
  encoding: 'utf8', timeout: 120000,
});
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) throw result.error;
process.exit(result.status ?? 1);
