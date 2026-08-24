// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CefKit
import AppKit
import Foundation

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
            case ("POST", "/api/open-vault"):
                let vaultURL = try await store.prepareVault(storageDirectory: storageDirectory)
                let opened = await MainActor.run { NSWorkspace.shared.open(vaultURL) }
                return try Self.jsonResponse(["opened": opened], status: opened ? 200 : 500)
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

    private static let securityHeaders = [
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src data:",
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
            main { width: min(860px, calc(100% - 48px)); margin: 52px auto 80px; }
            h1 { margin: 0; font-size: 34px; letter-spacing: -0.03em; }
            .intro { margin: 10px 0 28px; color: GrayText; line-height: 1.5; }
            .privacy { padding: 14px 16px; border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 12px; background: color-mix(in srgb, CanvasText 4%, transparent); font-size: 13px; line-height: 1.5; }
            form { margin: 24px 0 32px; }
            textarea { width: 100%; min-height: 112px; resize: vertical; padding: 14px; border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); border-radius: 12px; background: Canvas; color: CanvasText; font: inherit; line-height: 1.45; }
            textarea:focus { outline: 2px solid #6d5ce7; outline-offset: 1px; }
            .form-row, .memory-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
            .form-row { margin-top: 10px; }
            .counter, #status, time { color: GrayText; font-size: 12px; }
            button { appearance: none; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 8px; padding: 8px 13px; background: color-mix(in srgb, CanvasText 7%, transparent); color: CanvasText; font: inherit; font-weight: 600; cursor: pointer; }
            button.primary { color: white; background: #6d5ce7; border-color: #6d5ce7; }
            button.danger { color: #d83b3b; }
            button:disabled { opacity: 0.5; cursor: default; }
            h2 { margin: 0; font-size: 19px; }
            #list { display: grid; gap: 12px; margin-top: 14px; }
            article { padding: 16px; border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 12px; }
            article p { margin: 0 0 12px; white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.5; }
            .item-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
            .empty { padding: 38px 16px; text-align: center; color: GrayText; border: 1px dashed color-mix(in srgb, CanvasText 18%, transparent); border-radius: 12px; }
            @media (max-width: 560px) { main { width: min(100% - 28px, 860px); margin-top: 28px; } .memory-head { align-items: flex-start; } }
          </style>
        </head>
        <body>
          <main>
            <h1>Local AI Memory</h1>
            <p class="intro">Save durable facts and preferences that Astra can retrieve when they are relevant to a future question. Completed user and AI turns are also remembered automatically.</p>
            <div class="privacy"><strong>Markdown vault + local vector index.</strong> Every memory is mirrored as a portable Markdown file in your account folder. Astra performs similarity search on-device. Relevant entries are sent to your configured ZenMux model only when you ask a question; expired conversation batches are sent when Astra compacts them. Conversation memories expire after 90 days or when more than 2,000 accumulate. Astra deletes originals only after their summary is saved.</div>
            <form id="form">
              <textarea id="text" maxlength="4000" placeholder="For example: I prefer concise answers with a short summary first." aria-label="Memory text"></textarea>
              <div class="form-row"><span><span id="status" role="status"></span></span><span><span class="counter" id="counter">0 / 4000</span> <button class="primary" id="save" type="submit">Save memory</button></span></div>
            </form>
            <section>
              <div class="memory-head"><h2>Saved memories <span id="count"></span></h2><span><button id="open-vault" type="button">Open Markdown folder</button> <button class="danger" id="clear" type="button">Clear all</button></span></div>
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
            const counter = document.querySelector('#counter');

            async function request(path, options = {}) {
              const response = await fetch(path, options);
              const payload = await response.json().catch(() => ({}));
              if (!response.ok) throw new Error(payload.error || `Request failed (${response.status})`);
              return payload;
            }

            function setBusy(busy) {
              save.disabled = busy;
              clear.disabled = busy;
              openVault.disabled = busy;
            }

            function showStatus(message, isError = false) {
              status.textContent = message;
              status.style.color = isError ? '#d83b3b' : '';
            }

            function render(memories) {
              list.replaceChildren();
              count.textContent = `(${memories.length})`;
              clear.hidden = memories.length === 0;
              if (memories.length === 0) {
                const empty = document.createElement('div');
                empty.className = 'empty';
                empty.textContent = 'No memories saved yet.';
                list.append(empty);
                return;
              }
              for (const memory of memories) {
                const article = document.createElement('article');
                const body = document.createElement('p');
                body.textContent = memory.text;
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
                    await load();
                    showStatus('Memory deleted.');
                  } catch (error) {
                    showStatus(error.message, true);
                  } finally { setBusy(false); }
                });
                row.append(date, remove);
                article.append(body, row);
                list.append(article);
              }
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
            clear.addEventListener('click', async () => {
              if (!confirm('Delete every saved memory from this Mac?')) return;
              setBusy(true);
              try {
                await request('/api/memories', { method: 'DELETE' });
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
