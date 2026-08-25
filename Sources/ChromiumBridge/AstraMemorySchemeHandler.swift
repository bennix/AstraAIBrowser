// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CefKit
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Serves Astra's account-scoped local memory UI and its same-origin API.
/// The page CSP blocks all remote content while CORS remains enabled so the
/// page can call its own Fetch API endpoints through Chromium.
struct AstraMemorySchemeHandler: CefSchemeHandler {
    static let schemeName = "astra"
    static let domain = "memory"
    static let pageURL = URLProcessor.browserMemoryURL
    static let customScheme = CefCustomScheme(
        name: schemeName,
        options: [.standard, .secure, .corsEnabled, .fetchEnabled]
    )

    private struct CreateRequest: Decodable {
        let text: String
    }

    private struct ExportRequest: Decodable {
        let ids: [UUID]
    }

    private struct ExportResponse: Encodable {
        let exportedCount: Int
        let cancelled: Bool
    }

    private struct MemoryResponse: Encodable {
        let id: UUID
        let text: String
        let source: AIMemorySource
        let createdAt: Date
        let updatedAt: Date

        init(_ record: AIMemoryRecord) {
            id = record.id
            text = record.text
            source = record.source
            createdAt = record.createdAt
            updatedAt = record.updatedAt
        }
    }

    private struct ErrorResponse: Encodable {
        let error: String
    }

    let storageDirectoryProvider: @Sendable () async -> URL
    private let store: AIMemoryStore

    init(
        store: AIMemoryStore = .shared,
        storageDirectoryProvider: @escaping @Sendable () async -> URL
    ) {
        self.store = store
        self.storageDirectoryProvider = storageDirectoryProvider
    }

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == Self.schemeName,
              url.host?.lowercased() == Self.domain else {
            return .notFound()
        }

        if request.method == "GET", url.path == "/" || url.path.isEmpty {
            return Self.htmlResponse
        }

        let storageDirectory = await storageDirectoryProvider()
        do {
            switch (request.method, url.path) {
            case ("GET", "/api/memories"):
                let records = try await store.list(storageDirectory: storageDirectory)
                return try Self.jsonResponse(records.map(MemoryResponse.init))
            case ("POST", "/api/memories"):
                guard let body = request.body else {
                    return try Self.jsonError("The request body is missing.", status: 400)
                }
                let createRequest = try JSONDecoder().decode(CreateRequest.self, from: body)
                let record = try await store.add(
                    createRequest.text,
                    storageDirectory: storageDirectory
                )
                return try Self.jsonResponse(MemoryResponse(record), status: 201)
            case ("DELETE", "/api/memories"):
                try await store.deleteAll(storageDirectory: storageDirectory)
                return try Self.jsonResponse([String: Bool](dictionaryLiteral: ("deleted", true)))
            case ("POST", "/api/export"):
                guard let body = request.body else {
                    return try Self.jsonError("The request body is missing.", status: 400)
                }
                let exportRequest = try JSONDecoder().decode(ExportRequest.self, from: body)
                guard !exportRequest.ids.isEmpty, exportRequest.ids.count <= 2_000 else {
                    return try Self.jsonError("Select between 1 and 2,000 memories.", status: 400)
                }
                let records = try await store.records(
                    ids: exportRequest.ids,
                    storageDirectory: storageDirectory
                )
                guard records.count == exportRequest.ids.count else {
                    return try Self.jsonError("One or more selected memories no longer exist.", status: 404)
                }
                guard let destinationURL = await Self.chooseExportDestination(for: records) else {
                    return try Self.jsonResponse(ExportResponse(exportedCount: 0, cancelled: true))
                }
                let exportedURLs = try await store.export(
                    ids: exportRequest.ids,
                    to: destinationURL,
                    storageDirectory: storageDirectory
                )
                return try Self.jsonResponse(
                    ExportResponse(exportedCount: exportedURLs.count, cancelled: false)
                )
            case ("POST", "/api/open-vault"):
                let vaultURL = try await store.prepareVault(storageDirectory: storageDirectory)
                let opened = await MainActor.run { NSWorkspace.shared.open(vaultURL) }
                return try Self.jsonResponse(["opened": opened], status: opened ? 200 : 500)
            case ("GET", "/api/formula"):
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let latex = components.queryItems?.first(where: { $0.name == "latex" })?.value,
                      !latex.isEmpty,
                      latex.count <= 4_000 else {
                    return try Self.jsonError("The formula is missing or too long.", status: 400)
                }
                let display = components.queryItems?.first(where: { $0.name == "display" })?.value == "true"
                let darkAppearance = components.queryItems?.first(where: { $0.name == "appearance" })?.value == "dark"
                guard let pngData = await Self.renderFormula(
                    latex,
                    display: display,
                    darkAppearance: darkAppearance
                ) else {
                    return try Self.jsonError("The formula could not be rendered.", status: 422)
                }
                return CefSchemeResponse(
                    status: 200,
                    headers: Self.securityHeaders,
                    mimeType: "image/png",
                    body: pngData
                )
            case ("DELETE", let path) where path.hasPrefix("/api/memories/"):
                let rawID = String(path.dropFirst("/api/memories/".count))
                guard let id = UUID(uuidString: rawID) else {
                    return try Self.jsonError("The memory identifier is invalid.", status: 400)
                }
                let deleted = try await store.delete(id: id, storageDirectory: storageDirectory)
                return try Self.jsonResponse(["deleted": deleted], status: deleted ? 200 : 404)
            default:
                return .notFound()
            }
        } catch let error as DecodingError {
            return (try? Self.jsonError("The request body is invalid: \(error.localizedDescription)", status: 400))
                ?? .notFound()
        } catch {
            return (try? Self.jsonError(error.localizedDescription, status: 500))
                ?? .notFound()
        }
    }

    private static var htmlResponse: CefSchemeResponse {
        CefSchemeResponse(
            status: 200,
            headers: securityHeaders,
            mimeType: "text/html",
            body: Data(pageHTML.utf8)
        )
    }

    private static func jsonResponse<Value: Encodable>(
        _ value: Value,
        status: Int = 200
    ) throws -> CefSchemeResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return CefSchemeResponse(
            status: status,
            headers: securityHeaders,
            mimeType: "application/json",
            body: try encoder.encode(value)
        )
    }

    private static func jsonError(_ message: String, status: Int) throws -> CefSchemeResponse {
        try jsonResponse(ErrorResponse(error: message), status: status)
    }

    @MainActor
    private static func chooseExportDestination(for records: [AIMemoryRecord]) -> URL? {
        if records.count == 1, let record = records.first {
            let panel = NSSavePanel()
            panel.title = NSLocalizedString(
                "memory.export.singlePanel.title",
                value: "Export Memory",
                comment: "Local AI Memory - Save panel title for exporting one memory as a Markdown file"
            )
            panel.prompt = NSLocalizedString(
                "memory.export.panel.exportButton",
                value: "Export",
                comment: "Local AI Memory - Primary button in the single or multiple memory export panel"
            )
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = suggestedFilename(for: record)
            return panel.runModal() == .OK ? panel.url : nil
        }

        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(
            "memory.export.multiplePanel.title",
            value: "Export Memories",
            comment: "Local AI Memory - Folder picker title for exporting several memories as Markdown files"
        )
        panel.prompt = NSLocalizedString(
            "memory.export.panel.exportButton",
            value: "Export",
            comment: "Local AI Memory - Primary button in the single or multiple memory export panel"
        )
        panel.message = NSLocalizedString(
            "memory.export.multiplePanel.message",
            value: "Choose a folder for the selected Markdown files.",
            comment: "Local AI Memory - Explanation in the folder picker used for multiple memory export"
        )
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func suggestedFilename(for record: AIMemoryRecord) -> String {
        let firstLine = record.text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let safeTitle = firstLine
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let title = safeTitle.isEmpty ? "Astra Memory" : String(safeTitle.prefix(64))
        return title.hasSuffix(".md") ? title : "\(title).md"
    }

    @MainActor
    private static func renderFormula(
        _ latex: String,
        display: Bool,
        darkAppearance: Bool
    ) -> Data? {
        guard let rendered = ZenMuxMathRenderer.render(
            latex: ZenMuxMarkdownNormalizer.normalize(latex),
            fontSize: display ? 18 : 15,
            textColor: darkAppearance ? .white : .labelColor,
            labelMode: display ? .display : .text
        ), let tiffData = rendered.image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static let securityHeaders = [
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
    ]

    private static let pageHTML = #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Local AI Memory</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            * { box-sizing: border-box; }
            body { margin: 0; background: Canvas; color: CanvasText; }
            main { width: min(940px, calc(100% - 48px)); margin: 52px auto 80px; }
            h1 { margin: 0; font-size: 34px; letter-spacing: -0.03em; }
            .intro { margin: 10px 0 28px; color: GrayText; line-height: 1.5; }
            .privacy { padding: 14px 16px; border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 12px; background: color-mix(in srgb, CanvasText 4%, transparent); font-size: 13px; line-height: 1.5; }
            form { margin: 24px 0 32px; }
            textarea { width: 100%; min-height: 112px; resize: vertical; padding: 14px; border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); border-radius: 12px; background: Canvas; color: CanvasText; font: inherit; line-height: 1.45; }
            textarea:focus { outline: 2px solid #6d5ce7; outline-offset: 1px; }
            .form-row, .memory-head, .item-row, .article-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
            .form-row { margin-top: 10px; }
            .memory-head { align-items: flex-start; flex-wrap: wrap; }
            .toolbar { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px; }
            .counter, #status, time, .selection-label { color: GrayText; font-size: 12px; }
            button { appearance: none; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 8px; padding: 8px 13px; background: color-mix(in srgb, CanvasText 7%, transparent); color: CanvasText; font: inherit; font-weight: 600; cursor: pointer; }
            button.primary { color: white; background: #6d5ce7; border-color: #6d5ce7; }
            button.danger { color: #d83b3b; }
            button:disabled, input:disabled { opacity: 0.5; cursor: default; }
            h2 { margin: 0; font-size: 19px; }
            #list { display: grid; gap: 12px; margin-top: 14px; }
            article { padding: 16px; border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 12px; min-width: 0; }
            article.selected { border-color: #6d5ce7; box-shadow: 0 0 0 1px #6d5ce7 inset; }
            .article-head { justify-content: flex-start; margin-bottom: 12px; }
            .article-head input { width: 16px; height: 16px; accent-color: #6d5ce7; }
            .markdown-body { min-width: 0; overflow-wrap: anywhere; line-height: 1.55; }
            .markdown-body > :first-child { margin-top: 0; }
            .markdown-body > :last-child { margin-bottom: 0; }
            .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4, .markdown-body h5, .markdown-body h6 { margin: 18px 0 8px; letter-spacing: normal; }
            .markdown-body h1 { font-size: 23px; } .markdown-body h2 { font-size: 20px; } .markdown-body h3 { font-size: 17px; }
            .markdown-body h4, .markdown-body h5, .markdown-body h6 { font-size: 15px; }
            .markdown-body p { margin: 9px 0; white-space: normal; }
            .markdown-body ul, .markdown-body ol { margin: 9px 0; padding-left: 26px; }
            .markdown-body li { margin: 4px 0; }
            .markdown-body blockquote { margin: 10px 0; padding: 2px 0 2px 12px; color: GrayText; border-left: 3px solid color-mix(in srgb, CanvasText 24%, transparent); }
            .markdown-body pre { margin: 10px 0; padding: 12px; overflow-x: auto; border-radius: 8px; background: color-mix(in srgb, CanvasText 7%, transparent); }
            .markdown-body code { padding: 2px 4px; border-radius: 4px; background: color-mix(in srgb, CanvasText 7%, transparent); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
            .markdown-body pre code { padding: 0; background: transparent; }
            .markdown-body a { color: LinkText; }
            .table-scroll { width: 100%; margin: 12px 0; overflow-x: auto; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 8px; }
            table { width: max-content; min-width: 100%; border-collapse: collapse; font-size: 13px; }
            th, td { min-width: 120px; padding: 8px 10px; text-align: left; vertical-align: top; border-right: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }
            th { background: color-mix(in srgb, CanvasText 8%, transparent); font-weight: 650; }
            tr:last-child td { border-bottom: 0; } th:last-child, td:last-child { border-right: 0; }
            .formula { max-width: 100%; object-fit: contain; vertical-align: middle; }
            .formula.inline { display: inline-block; height: auto; max-height: 2.4em; margin: 0 2px; }
            .formula.display { display: block; width: auto; margin: 12px 0; overflow-x: auto; }
            .formula-fallback { color: GrayText; }
            .item-row { margin-top: 14px; }
            .empty { padding: 38px 16px; text-align: center; color: GrayText; border: 1px dashed color-mix(in srgb, CanvasText 18%, transparent); border-radius: 12px; }
            @media (max-width: 560px) { main { width: min(100% - 28px, 940px); margin-top: 28px; } .toolbar { justify-content: flex-start; } }
          </style>
        </head>
        <body>
          <main>
            <h1>Local AI Memory</h1>
            <p class="intro">Save durable facts and preferences that Astra can retrieve when they are relevant to a future question. Markdown, tables, and LaTeX formulas render locally. Completed user and AI turns are also remembered automatically.</p>
            <div class="privacy"><strong>Markdown vault + local vector index.</strong> Every memory is mirrored as a portable Markdown file in your account folder. Astra performs similarity search on-device. Relevant entries are sent to your configured ZenMux model only when you ask a question; expired conversation batches are sent when Astra compacts them. Conversation memories expire after 90 days or when more than 2,000 accumulate. Astra deletes originals only after their summary is saved.</div>
            <form id="form">
              <textarea id="text" maxlength="4000" placeholder="For example: I prefer concise answers with a short summary first." aria-label="Memory text"></textarea>
              <div class="form-row"><span><span id="status" role="status"></span></span><span><span class="counter" id="counter">0 / 4000</span> <button class="primary" id="save" type="submit">Save memory</button></span></div>
            </form>
            <section>
              <div class="memory-head">
                <h2>Saved memories <span id="count"></span></h2>
                <div class="toolbar">
                  <button id="select-all" type="button">Select all</button>
                  <button id="export" type="button" disabled>Export selected</button>
                  <button id="open-vault" type="button">Open Markdown folder</button>
                  <button class="danger" id="clear" type="button">Clear all</button>
                </div>
              </div>
              <div id="list" aria-live="polite"></div>
            </section>
          </main>
          <script>
            const form = document.querySelector('#form');
            const text = document.querySelector('#text');
            const save = document.querySelector('#save');
            const status = document.querySelector('#status');
            const list = document.querySelector('#list');
            const count = document.querySelector('#count');
            const clear = document.querySelector('#clear');
            const openVault = document.querySelector('#open-vault');
            const selectAll = document.querySelector('#select-all');
            const exportSelected = document.querySelector('#export');
            const counter = document.querySelector('#counter');
            const selectedIDs = new Set();
            let currentMemories = [];
            let isBusy = false;

            async function request(path, options = {}) {
              const response = await fetch(path, options);
              const payload = await response.json().catch(() => ({}));
              if (!response.ok) throw new Error(payload.error || `Request failed (${response.status})`);
              return payload;
            }

            function setBusy(busy) {
              isBusy = busy;
              save.disabled = busy;
              clear.disabled = busy;
              openVault.disabled = busy;
              selectAll.disabled = busy || currentMemories.length === 0;
              document.querySelectorAll('input[type="checkbox"]').forEach(input => { input.disabled = busy; });
              updateSelectionControls();
            }

            function showStatus(message, isError = false) {
              status.textContent = message;
              status.style.color = isError ? '#d83b3b' : '';
            }

            function updateSelectionControls() {
              const selectedCount = selectedIDs.size;
              exportSelected.disabled = isBusy || selectedCount === 0;
              exportSelected.textContent = selectedCount === 0 ? 'Export selected' : `Export selected (${selectedCount})`;
              selectAll.textContent = selectedCount === currentMemories.length && selectedCount > 0 ? 'Clear selection' : 'Select all';
            }

            function isDarkAppearance() {
              return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
            }

            function formulaImage(latex, display) {
              const image = document.createElement('img');
              image.className = `formula ${display ? 'display' : 'inline'}`;
              image.alt = latex;
              const query = new URLSearchParams({
                latex,
                display: String(display),
                appearance: isDarkAppearance() ? 'dark' : 'light'
              });
              image.src = `/api/formula?${query}`;
              image.addEventListener('error', () => {
                const fallback = document.createElement(display ? 'pre' : 'code');
                fallback.className = 'formula-fallback';
                fallback.textContent = latex;
                image.replaceWith(fallback);
              });
              return image;
            }

            function appendInline(container, source) {
              const tokenPattern = /(`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__|\\\([^\n]+?\\\)|\$[^$\n]+?\$|\[[^\]\n]+\]\([^\s)]+\)|\*[^*\n]+\*|_[^_\n]+_)/g;
              let cursor = 0;
              for (const match of source.matchAll(tokenPattern)) {
                if (match.index > cursor) container.append(document.createTextNode(source.slice(cursor, match.index)));
                const token = match[0];
                if (token.startsWith('`')) {
                  const code = document.createElement('code');
                  code.textContent = token.slice(1, -1);
                  container.append(code);
                } else if (token.startsWith('**') || token.startsWith('__')) {
                  const strong = document.createElement('strong');
                  appendInline(strong, token.slice(2, -2));
                  container.append(strong);
                } else if (token.startsWith('\\(')) {
                  container.append(formulaImage(token.slice(2, -2), false));
                } else if (token.startsWith('$')) {
                  container.append(formulaImage(token.slice(1, -1), false));
                } else if (token.startsWith('[')) {
                  const split = token.indexOf('](');
                  const anchor = document.createElement('a');
                  anchor.textContent = token.slice(1, split);
                  const href = token.slice(split + 2, -1);
                  try {
                    const url = new URL(href);
                    if (url.protocol === 'http:' || url.protocol === 'https:') {
                      anchor.href = url.href;
                      anchor.target = '_blank';
                      anchor.rel = 'noreferrer';
                    }
                  } catch (_) {}
                  container.append(anchor);
                } else {
                  const emphasis = document.createElement('em');
                  appendInline(emphasis, token.slice(1, -1));
                  container.append(emphasis);
                }
                cursor = match.index + token.length;
              }
              if (cursor < source.length) container.append(document.createTextNode(source.slice(cursor)));
            }

            function appendParagraph(container, lines) {
              const paragraph = document.createElement('p');
              lines.forEach((line, index) => {
                if (index > 0) paragraph.append(document.createElement('br'));
                appendInline(paragraph, line);
              });
              container.append(paragraph);
            }

            function tableCells(line) {
              const trimmed = line.trim();
              if (!trimmed.includes('|')) return null;
              const cells = [''];
              let escaped = false;
              for (const character of trimmed) {
                if (escaped) {
                  cells[cells.length - 1] += character === '|' ? '|' : `\\${character}`;
                  escaped = false;
                } else if (character === '\\') {
                  escaped = true;
                } else if (character === '|') {
                  cells.push('');
                } else {
                  cells[cells.length - 1] += character;
                }
              }
              if (escaped) cells[cells.length - 1] += '\\';
              if (trimmed.startsWith('|') && cells[0] === '') cells.shift();
              if (trimmed.endsWith('|') && cells[cells.length - 1] === '') cells.pop();
              return cells.map(cell => cell.trim());
            }

            function isTableDelimiter(cells) {
              return cells && cells.length > 0 && cells.every(cell => /^:?-{3,}:?$/.test(cell));
            }

            function appendTable(container, headers, rows) {
              const scroller = document.createElement('div');
              scroller.className = 'table-scroll';
              const table = document.createElement('table');
              const head = document.createElement('thead');
              const headerRow = document.createElement('tr');
              headers.forEach(cell => {
                const heading = document.createElement('th');
                appendInline(heading, cell);
                headerRow.append(heading);
              });
              head.append(headerRow);
              table.append(head);
              const body = document.createElement('tbody');
              rows.forEach(row => {
                const tableRow = document.createElement('tr');
                headers.forEach((_, index) => {
                  const cell = document.createElement('td');
                  appendInline(cell, row[index] || '');
                  tableRow.append(cell);
                });
                body.append(tableRow);
              });
              table.append(body);
              scroller.append(table);
              container.append(scroller);
            }

            function startsBlock(lines, index) {
              const value = lines[index]?.trim() || '';
              if (!value) return true;
              if (/^```/.test(value) || /^#{1,6}\s/.test(value) || /^>\s?/.test(value)) return true;
              if (/^([-+*])\s+/.test(value) || /^\d+[.)]\s+/.test(value)) return true;
              if (value.startsWith('$$') || value.startsWith('\\[')) return true;
              const cells = tableCells(lines[index]);
              return cells && isTableDelimiter(tableCells(lines[index + 1] || ''));
            }

            function renderMarkdown(source) {
              const container = document.createElement('div');
              container.className = 'markdown-body';
              const lines = source.replace(/\r\n?/g, '\n').split('\n');
              let index = 0;
              while (index < lines.length) {
                const line = lines[index];
                const trimmed = line.trim();
                if (!trimmed) { index += 1; continue; }

                if (trimmed.startsWith('```')) {
                  const codeLines = [];
                  index += 1;
                  while (index < lines.length && !lines[index].trim().startsWith('```')) {
                    codeLines.push(lines[index]);
                    index += 1;
                  }
                  if (index < lines.length) index += 1;
                  const pre = document.createElement('pre');
                  const code = document.createElement('code');
                  code.textContent = codeLines.join('\n');
                  pre.append(code);
                  container.append(pre);
                  continue;
                }

                if (trimmed.startsWith('$$') || trimmed.startsWith('\\[')) {
                  const closing = trimmed.startsWith('$$') ? '$$' : '\\]';
                  let formula = trimmed.slice(2);
                  if (formula.endsWith(closing) && formula.length > closing.length) {
                    formula = formula.slice(0, -2);
                    index += 1;
                  } else {
                    const formulaLines = formula ? [formula] : [];
                    index += 1;
                    while (index < lines.length && !lines[index].trim().endsWith(closing)) {
                      formulaLines.push(lines[index]);
                      index += 1;
                    }
                    if (index < lines.length) {
                      formulaLines.push(lines[index].trim().slice(0, -2));
                      index += 1;
                    }
                    formula = formulaLines.join('\n');
                  }
                  container.append(formulaImage(formula.trim(), true));
                  continue;
                }

                const heading = trimmed.match(/^(#{1,6})\s+(.+)$/);
                if (heading) {
                  const element = document.createElement(`h${heading[1].length}`);
                  appendInline(element, heading[2]);
                  container.append(element);
                  index += 1;
                  continue;
                }

                const headers = tableCells(line);
                if (headers && headers.length >= 2 && isTableDelimiter(tableCells(lines[index + 1] || ''))) {
                  const rows = [];
                  index += 2;
                  while (index < lines.length) {
                    const cells = tableCells(lines[index]);
                    if (!cells || isTableDelimiter(cells)) break;
                    rows.push(cells);
                    index += 1;
                  }
                  appendTable(container, headers, rows);
                  continue;
                }

                if (/^([-+*])\s+/.test(trimmed) || /^\d+[.)]\s+/.test(trimmed)) {
                  const ordered = /^\d+[.)]\s+/.test(trimmed);
                  const listElement = document.createElement(ordered ? 'ol' : 'ul');
                  while (index < lines.length) {
                    const value = lines[index].trim();
                    const match = ordered ? value.match(/^\d+[.)]\s+(.+)$/) : value.match(/^[-+*]\s+(.+)$/);
                    if (!match) break;
                    const item = document.createElement('li');
                    appendInline(item, match[1]);
                    listElement.append(item);
                    index += 1;
                  }
                  container.append(listElement);
                  continue;
                }

                if (trimmed.startsWith('>')) {
                  const quote = document.createElement('blockquote');
                  const quoteLines = [];
                  while (index < lines.length && lines[index].trim().startsWith('>')) {
                    quoteLines.push(lines[index].trim().replace(/^>\s?/, ''));
                    index += 1;
                  }
                  appendParagraph(quote, quoteLines);
                  container.append(quote);
                  continue;
                }

                const paragraphLines = [line];
                index += 1;
                while (index < lines.length && !startsBlock(lines, index)) {
                  paragraphLines.push(lines[index]);
                  index += 1;
                }
                appendParagraph(container, paragraphLines);
              }
              return container;
            }

            function render(memories) {
              currentMemories = memories;
              const currentIDs = new Set(memories.map(memory => memory.id));
              for (const id of selectedIDs) if (!currentIDs.has(id)) selectedIDs.delete(id);
              list.replaceChildren();
              count.textContent = `(${memories.length})`;
              clear.hidden = memories.length === 0;
              selectAll.disabled = isBusy || memories.length === 0;
              if (memories.length === 0) {
                const empty = document.createElement('div');
                empty.className = 'empty';
                empty.textContent = 'No memories saved yet.';
                list.append(empty);
                updateSelectionControls();
                return;
              }
              for (const memory of memories) {
                const article = document.createElement('article');
                article.classList.toggle('selected', selectedIDs.has(memory.id));
                const articleHead = document.createElement('div');
                articleHead.className = 'article-head';
                const checkbox = document.createElement('input');
                checkbox.type = 'checkbox';
                checkbox.checked = selectedIDs.has(memory.id);
                checkbox.disabled = isBusy;
                checkbox.setAttribute('aria-label', 'Select this memory');
                const selectionLabel = document.createElement('span');
                selectionLabel.className = 'selection-label';
                selectionLabel.textContent = 'Select for export';
                checkbox.addEventListener('change', () => {
                  if (checkbox.checked) selectedIDs.add(memory.id); else selectedIDs.delete(memory.id);
                  article.classList.toggle('selected', checkbox.checked);
                  updateSelectionControls();
                });
                articleHead.append(checkbox, selectionLabel);
                const body = renderMarkdown(memory.text);
                const row = document.createElement('div');
                row.className = 'item-row';
                const date = document.createElement('time');
                date.dateTime = memory.updatedAt;
                const sourceLabel = memory.source === 'conversation' ? 'Conversation memory' : (memory.source === 'summary' ? 'Compacted summary' : 'Manual memory');
                date.textContent = `${sourceLabel} · ${new Date(memory.updatedAt).toLocaleString()}`;
                const remove = document.createElement('button');
                remove.type = 'button';
                remove.className = 'danger';
                remove.textContent = 'Delete';
                remove.addEventListener('click', async () => {
                  setBusy(true);
                  try {
                    await request(`/api/memories/${memory.id}`, { method: 'DELETE' });
                    selectedIDs.delete(memory.id);
                    await load();
                    showStatus('Memory deleted.');
                  } catch (error) {
                    showStatus(error.message, true);
                  } finally { setBusy(false); }
                });
                row.append(date, remove);
                article.append(articleHead, body, row);
                list.append(article);
              }
              updateSelectionControls();
            }

            async function load() {
              render(await request('/api/memories'));
            }

            text.addEventListener('input', () => { counter.textContent = `${text.value.length} / 4000`; });
            form.addEventListener('submit', async event => {
              event.preventDefault();
              if (!text.value.trim()) return;
              setBusy(true);
              showStatus('Saving…');
              try {
                await request('/api/memories', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ text: text.value })
                });
                text.value = '';
                counter.textContent = '0 / 4000';
                await load();
                showStatus('Saved locally.');
              } catch (error) {
                showStatus(error.message, true);
              } finally { setBusy(false); }
            });
            selectAll.addEventListener('click', () => {
              if (selectedIDs.size === currentMemories.length) selectedIDs.clear();
              else currentMemories.forEach(memory => selectedIDs.add(memory.id));
              render(currentMemories);
            });
            exportSelected.addEventListener('click', async () => {
              if (selectedIDs.size === 0) return;
              setBusy(true);
              showStatus('Preparing Markdown export…');
              try {
                const result = await request('/api/export', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ ids: Array.from(selectedIDs) })
                });
                if (!result.cancelled) showStatus(`Exported ${result.exportedCount} Markdown file${result.exportedCount === 1 ? '' : 's'}.`);
                else showStatus('Export cancelled.');
              } catch (error) {
                showStatus(error.message, true);
              } finally { setBusy(false); }
            });
            clear.addEventListener('click', async () => {
              if (!confirm('Delete every saved memory from this Mac?')) return;
              setBusy(true);
              try {
                await request('/api/memories', { method: 'DELETE' });
                selectedIDs.clear();
                await load();
                showStatus('All memories deleted.');
              } catch (error) {
                showStatus(error.message, true);
              } finally { setBusy(false); }
            });
            openVault.addEventListener('click', async () => {
              setBusy(true);
              try {
                await request('/api/open-vault', { method: 'POST' });
                showStatus('Markdown folder opened in Finder.');
              } catch (error) {
                showStatus(error.message, true);
              } finally { setBusy(false); }
            });

            load().catch(error => showStatus(error.message, true));
          </script>
        </body>
        </html>
        """#
}
