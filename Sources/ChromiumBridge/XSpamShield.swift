// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct XSpamShieldRemoteMetadata: Decodable, Equatable, Sendable {
    struct Artifacts: Decodable, Equatable, Sendable {
        let lite: String
    }

    let count: Int
    let generatedAt: Int64
    let version: String
    let artifacts: Artifacts
}

struct XSpamShieldGitHubRevision: Decodable, Equatable, Sendable {
    struct Commit: Decodable, Equatable, Sendable {
        struct Identity: Decodable, Equatable, Sendable {
            let date: Date
        }

        let committer: Identity
    }

    let sha: String
    let commit: Commit
}

enum XSpamShieldGitHubFile: String, Sendable {
    case filteringDatabase = "data/blacklist/v2-lite.json"
    case whitelist = "data/whitelist/v1.json"
}

enum XSpamShieldDataSource: String, Codable, Sendable {
    case primarySite
    case githubMirror
}

struct XSpamShieldStatus: Codable, Equatable, Sendable {
    let revision: String
    let blacklistCount: Int
    let whitelistCount: Int
    let generatedAt: Date
    let updatedAt: Date
    let source: XSpamShieldDataSource
}

struct XSpamShieldMatch: Codable, Equatable, Sendable {
    let handle: String
    let label: String
    let isHidden: Bool
}

enum XSpamShieldListPolicy {
    struct Snapshot: Equatable {
        let version: String
        let entryCount: Int
        let labelsByHandle: [String: String]
        let whitelistedHandles: Set<String>

        func matches(handles: [String], hiddenHandles: Set<String>) -> [XSpamShieldMatch] {
            var seen = Set<String>()
            return handles.compactMap { rawHandle in
                let handle = Self.normalizedHandle(rawHandle)
                guard !handle.isEmpty,
                      seen.insert(handle).inserted,
                      !whitelistedHandles.contains(handle),
                      let label = labelsByHandle[handle] else { return nil }
                return XSpamShieldMatch(
                    handle: handle,
                    label: label,
                    isHidden: hiddenHandles.contains(handle)
                )
            }
        }

        static func normalizedHandle(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                .lowercased()
        }
    }

    private struct LitePayload: Decodable {
        let schema: Int?
        let generatedAt: Int64?
        let count: Int?
        let version: String?
        let labels: [String: String]
        let entries: [[String]]
    }

    private struct WhitelistPayload: Decodable {
        struct Entry: Decodable {
            let handle: String
        }

        let generatedAt: Int64?
        let latestAt: Int64?
        let count: Int
        let list: [Entry]
    }

    static func decodeSnapshot(liteData: Data, whitelistData: Data) throws -> Snapshot {
        let lite = try JSONDecoder().decode(LitePayload.self, from: liteData)
        let whitelist = try JSONDecoder().decode(WhitelistPayload.self, from: whitelistData)
        if let declaredCount = lite.count, declaredCount != lite.entries.count {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard whitelist.count == whitelist.list.count else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var labelsByHandle: [String: String] = [:]
        labelsByHandle.reserveCapacity(lite.entries.count)
        for entry in lite.entries {
            guard entry.count >= 3 else { continue }
            let handle = Snapshot.normalizedHandle(entry[1])
            guard !handle.isEmpty else { continue }
            let compactLabel = String(entry[2].prefix(1))
            labelsByHandle[handle] = lite.labels[compactLabel] ?? "junk"
        }

        let whitelistedHandles = Set(whitelist.list.map {
            Snapshot.normalizedHandle($0.handle)
        }.filter { !$0.isEmpty })

        return Snapshot(
            version: lite.version
                ?? lite.generatedAt.map(String.init)
                ?? lite.schema.map { "schema-\($0)" }
                ?? "unknown",
            entryCount: lite.entries.count,
            labelsByHandle: labelsByHandle,
            whitelistedHandles: whitelistedHandles
        )
    }

    static func whitelistSummary(
        whitelistData: Data
    ) throws -> (count: Int, generatedAt: Date?) {
        let whitelist = try JSONDecoder().decode(WhitelistPayload.self, from: whitelistData)
        guard whitelist.count == whitelist.list.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (
            whitelist.count,
            (whitelist.generatedAt ?? whitelist.latestAt).map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            }
        )
    }
}

actor XSpamShieldStore {
    static let shared = XSpamShieldStore()

    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let hiddenHandlesKey = "privacy.xSpamShield.hiddenHandles"

    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let userDefaults: UserDefaults
    private var snapshot: XSpamShieldListPolicy.Snapshot?
    private var currentStatus: XSpamShieldStatus?
    private var refreshTask: Task<Void, Never>?

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory
            ?? URL(fileURLWithPath: FileSystemUtils.cacheDirctory(), isDirectory: true)
                .appendingPathComponent("XSpamShield", isDirectory: true)
        self.userDefaults = userDefaults
    }

    func matches(handles: [String]) async -> [XSpamShieldMatch] {
        await prepareIfNeeded()
        guard let snapshot else { return [] }
        return snapshot.matches(handles: handles, hiddenHandles: hiddenHandles())
    }

    func status() async -> XSpamShieldStatus? {
        await prepareIfNeeded()
        return currentStatus
    }

    func updateNow() async throws -> XSpamShieldStatus {
        loadCachedSnapshot()
        if let refreshTask {
            await refreshTask.value
        }
        return try await refresh(force: true)
    }

    func setHidden(_ hidden: Bool, handle rawHandle: String) {
        let handle = XSpamShieldListPolicy.Snapshot.normalizedHandle(rawHandle)
        guard !handle.isEmpty else { return }
        var handles = hiddenHandles()
        if hidden {
            handles.insert(handle)
        } else {
            handles.remove(handle)
        }
        userDefaults.set(Array(handles).sorted(), forKey: Self.hiddenHandlesKey)
    }

    private func prepareIfNeeded() async {
        loadCachedSnapshot()
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.refresh(force: false)
            } catch {
                AppLogInfo("[XSpamShield] Public list refresh failed: \(error.localizedDescription)")
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func loadCachedSnapshot() {
        guard snapshot == nil,
              let liteData = try? Data(contentsOf: liteURL),
              let whitelistData = try? Data(contentsOf: whitelistURL),
              let cached = try? XSpamShieldListPolicy.decodeSnapshot(
                liteData: liteData,
                whitelistData: whitelistData
              ) else { return }
        snapshot = cached
        currentStatus = try? JSONDecoder().decode(
            XSpamShieldStatus.self,
            from: Data(contentsOf: metadataURL)
        )
    }

    private func refresh(force: Bool) async throws -> XSpamShieldStatus {
        if !force,
           let currentStatus,
           Date().timeIntervalSince(currentStatus.updatedAt) < Self.refreshInterval {
            return currentStatus
        }

        do {
            return try await refreshFromPrimarySite()
        } catch {
            AppLogInfo("[XSpamShield] Primary source failed; trying GitHub mirror: \(error.localizedDescription)")
            return try await refreshFromGitHubMirror()
        }
    }

    private func refreshFromPrimarySite() async throws -> XSpamShieldStatus {
        let metadata = try await APIClient.shared.fetchXSpamShieldMetadata()
        let whitelist = try await APIClient.shared.fetchXSpamShieldWhitelist()
        if let currentStatus,
           currentStatus.revision == metadata.version,
           currentStatus.source == .primarySite,
           let filteringDatabase = try? Data(contentsOf: liteURL) {
            return try install(
                filteringDatabase: filteringDatabase,
                whitelist: whitelist,
                revision: metadata.version,
                blacklistCount: metadata.count,
                generatedAt: Date(timeIntervalSince1970: Double(metadata.generatedAt) / 1_000),
                source: .primarySite
            )
        }

        let filteringDatabase = try await APIClient.shared.fetchXSpamShieldArtifact(
            at: metadata.artifacts.lite
        )
        return try install(
            filteringDatabase: filteringDatabase,
            whitelist: whitelist,
            revision: metadata.version,
            blacklistCount: metadata.count,
            generatedAt: Date(timeIntervalSince1970: Double(metadata.generatedAt) / 1_000),
            source: .primarySite
        )
    }

    private func refreshFromGitHubMirror() async throws -> XSpamShieldStatus {
        let revision = try await APIClient.shared.fetchXSpamShieldGitHubRevision()
        if let currentStatus,
           currentStatus.revision == revision.sha,
           currentStatus.source == .githubMirror {
            let updated = XSpamShieldStatus(
                revision: currentStatus.revision,
                blacklistCount: currentStatus.blacklistCount,
                whitelistCount: currentStatus.whitelistCount,
                generatedAt: currentStatus.generatedAt,
                updatedAt: Date(),
                source: .githubMirror
            )
            try persist(status: updated)
            return updated
        }

        async let filteringDatabase = APIClient.shared.fetchXSpamShieldGitHubFile(
            .filteringDatabase,
            revision: revision.sha
        )
        async let whitelist = APIClient.shared.fetchXSpamShieldGitHubFile(
            .whitelist,
            revision: revision.sha
        )
        let databaseData = try await filteringDatabase
        let whitelistData = try await whitelist
        let database = try XSpamShieldListPolicy.decodeSnapshot(
            liteData: databaseData,
            whitelistData: whitelistData
        )
        return try install(
            snapshot: database,
            filteringDatabase: databaseData,
            whitelist: whitelistData,
            revision: revision.sha,
            blacklistCount: database.entryCount,
            generatedAt: revision.commit.committer.date,
            source: .githubMirror
        )
    }

    private func install(
        filteringDatabase: Data,
        whitelist: Data,
        revision: String,
        blacklistCount: Int,
        generatedAt: Date,
        source: XSpamShieldDataSource
    ) throws -> XSpamShieldStatus {
        let decoded = try XSpamShieldListPolicy.decodeSnapshot(
            liteData: filteringDatabase,
            whitelistData: whitelist
        )
        return try install(
            snapshot: decoded,
            filteringDatabase: filteringDatabase,
            whitelist: whitelist,
            revision: revision,
            blacklistCount: blacklistCount,
            generatedAt: generatedAt,
            source: source
        )
    }

    private func install(
        snapshot: XSpamShieldListPolicy.Snapshot,
        filteringDatabase: Data,
        whitelist: Data,
        revision: String,
        blacklistCount: Int,
        generatedAt: Date,
        source: XSpamShieldDataSource
    ) throws -> XSpamShieldStatus {
        let whitelistSummary = try XSpamShieldListPolicy.whitelistSummary(
            whitelistData: whitelist
        )
        guard blacklistCount == snapshot.entryCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let status = XSpamShieldStatus(
            revision: revision,
            blacklistCount: blacklistCount,
            whitelistCount: whitelistSummary.count,
            generatedAt: max(generatedAt, whitelistSummary.generatedAt ?? generatedAt),
            updatedAt: Date(),
            source: source
        )
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try filteringDatabase.write(to: liteURL, options: .atomic)
        try whitelist.write(to: whitelistURL, options: .atomic)
        try persist(status: status)
        self.snapshot = snapshot
        return status
    }

    private func persist(status: XSpamShieldStatus) throws {
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(status).write(to: metadataURL, options: .atomic)
        currentStatus = status
    }

    private func hiddenHandles() -> Set<String> {
        Set((userDefaults.stringArray(forKey: Self.hiddenHandlesKey) ?? []).map {
            XSpamShieldListPolicy.Snapshot.normalizedHandle($0)
        })
    }

    private var liteURL: URL {
        cacheDirectory.appendingPathComponent("lite.json", isDirectory: false)
    }

    private var whitelistURL: URL {
        cacheDirectory.appendingPathComponent("whitelist.json", isDirectory: false)
    }

    private var metadataURL: URL {
        cacheDirectory.appendingPathComponent("metadata.json", isDirectory: false)
    }
}

enum XSpamShieldWebPolicy {
    static let messageHandlerName = "astraXSpamShield"

    static func javaScript(
        guardLabel: String,
        junkLabel: String,
        hideLabel: String,
        undoLabel: String,
        hiddenMessage: String
    ) -> String {
        let guardText = javaScriptLiteral(guardLabel)
        let junkText = javaScriptLiteral(junkLabel)
        let hideText = javaScriptLiteral(hideLabel)
        let undoText = javaScriptLiteral(undoLabel)
        let hiddenText = javaScriptLiteral(hiddenMessage)
        return """
        (() => {
          if (!/(^|\\.)x\\.com$|(^|\\.)twitter\\.com$/i.test(location.hostname)) return;
          if (window.__astraXSpamShieldInstalled) return;
          window.__astraXSpamShieldInstalled = true;

          const handler = window.webkit?.messageHandlers?.\(messageHandlerName);
          if (!handler) return;
          const matched = new Map();
          const articleHandles = new WeakMap();
          let scanTimer = null;
          let hitCount = 0;

          const normalize = (value) => String(value || '').replace(/^@/, '').trim().toLowerCase();
          const authorHandle = (article) => {
            const container = article.querySelector('[data-testid="User-Name"]') || article;
            for (const anchor of container.querySelectorAll('a[href]')) {
              try {
                const url = new URL(anchor.href, location.href);
                const parts = url.pathname.split('/').filter(Boolean);
                if (parts.length !== 1) continue;
                const handle = normalize(parts[0]);
                if (handle && !['home', 'explore', 'notifications', 'messages', 'i'].includes(handle)) {
                  return handle;
                }
              } catch (_) {}
            }
            return '';
          };

          const ensureStatus = () => {
            let host = document.getElementById('astra-x-spam-shield-status');
            if (host) return host.shadowRoot;
            host = document.createElement('div');
            host.id = 'astra-x-spam-shield-status';
            host.style.cssText = 'position:fixed;z-index:2147483646;top:18px;right:22px;pointer-events:none';
            const root = host.attachShadow({ mode: 'open' });
            root.innerHTML = `<style>
              .pill{display:flex;align-items:center;gap:7px;padding:8px 13px;border-radius:999px;
                background:rgba(255,255,255,.94);color:#0f1419;border:1px solid rgba(15,20,25,.12);
                box-shadow:0 6px 24px rgba(0,0,0,.12);font:600 14px -apple-system,BlinkMacSystemFont,sans-serif}
              .shield{width:18px;height:18px;border-radius:50%;display:grid;place-items:center;background:#1687c9;color:white}
            </style><div class="pill"><span class="shield">✓</span><span class="text"></span></div>`;
            (document.body || document.documentElement).appendChild(host);
            return root;
          };

          const updateStatus = () => {
            const root = ensureStatus();
            const text = root?.querySelector('.text');
            if (text) text.textContent = hitCount > 0 ? `\(guardText) ${hitCount}` : \(guardText);
          };

          const showUndo = (handle) => {
            let host = document.getElementById('astra-x-spam-shield-toast');
            if (host) host.remove();
            host = document.createElement('div');
            host.id = 'astra-x-spam-shield-toast';
            host.style.cssText = 'position:fixed;z-index:2147483647;left:50%;bottom:28px;transform:translateX(-50%)';
            const root = host.attachShadow({ mode: 'open' });
            const message = \(hiddenText).replace('%@', `@${handle}`);
            root.innerHTML = `<style>
              .toast{display:flex;align-items:center;gap:16px;padding:12px 16px;border-radius:12px;background:#0f1419;color:white;
                box-shadow:0 8px 30px rgba(0,0,0,.28);font:14px -apple-system,BlinkMacSystemFont,sans-serif}
              button{border:0;background:none;color:#55acee;font:700 14px inherit;cursor:pointer}
            </style><div class="toast"><span>${message}</span><button>\(undoText)</button></div>`;
            root.querySelector('button')?.addEventListener('click', () => {
              handler.postMessage({ type: 'unhide', handle });
              const match = matched.get(handle);
              if (match) matched.set(handle, { ...match, isHidden: false });
              document.querySelectorAll('article[data-astra-x-hidden="true"]').forEach((article) => {
                if (articleHandles.get(article) === handle) {
                  article.style.removeProperty('display');
                  article.removeAttribute('data-astra-x-hidden');
                }
              });
              host.remove();
            });
            (document.body || document.documentElement).appendChild(host);
            setTimeout(() => host?.remove(), 5000);
          };

          const decorate = (article, match) => {
            articleHandles.set(article, match.handle);
            if (match.isHidden) {
              article.style.setProperty('display', 'none', 'important');
              article.setAttribute('data-astra-x-hidden', 'true');
              return;
            }
            if (article.querySelector('[data-astra-x-spam-badge]')) return;
            const anchor = article.querySelector('[data-testid="User-Name"]') || article.firstElementChild;
            if (!anchor?.parentNode) return;
            const host = document.createElement('span');
            host.setAttribute('data-astra-x-spam-badge', match.handle);
            host.style.cssText = 'display:inline-block;margin:6px 12px 2px;vertical-align:middle';
            const root = host.attachShadow({ mode: 'open' });
            root.innerHTML = `<style>
              .badge{display:inline-flex;align-items:center;gap:7px;padding:5px 9px;border-radius:999px;background:#fff0f0;
                border:1px solid #ffd1d1;color:#b42318;font:700 12px -apple-system,BlinkMacSystemFont,sans-serif}
              button{border:0;border-radius:999px;background:#d92d20;color:white;padding:4px 9px;font:700 12px -apple-system,BlinkMacSystemFont,sans-serif;cursor:pointer}
            </style><span class="badge"><span>\(junkText)</span><button>\(hideText)</button></span>`;
            root.querySelector('button')?.addEventListener('click', () => {
              handler.postMessage({ type: 'hide', handle: match.handle });
              matched.set(match.handle, { ...match, isHidden: true });
              document.querySelectorAll('article').forEach((candidate) => {
                if (articleHandles.get(candidate) === match.handle) {
                  candidate.style.setProperty('display', 'none', 'important');
                  candidate.setAttribute('data-astra-x-hidden', 'true');
                }
              });
              showUndo(match.handle);
            });
            anchor.parentNode.insertBefore(host, anchor.nextSibling);
          };

          const apply = (matches) => {
            for (const match of matches || []) matched.set(normalize(match.handle), match);
            const hitHandles = new Set();
            document.querySelectorAll('article').forEach((article) => {
              const handle = authorHandle(article);
              if (!handle) return;
              articleHandles.set(article, handle);
              const match = matched.get(handle);
              if (!match) return;
              hitHandles.add(handle);
              decorate(article, match);
            });
            hitCount = hitHandles.size;
            updateStatus();
          };
          window.__astraXSpamShieldApply = apply;

          const scan = () => {
            scanTimer = null;
            const handles = [];
            const seen = new Set();
            document.querySelectorAll('article').forEach((article) => {
              const handle = authorHandle(article);
              if (handle && !seen.has(handle)) {
                seen.add(handle);
                handles.push(handle);
              }
            });
            if (handles.length) handler.postMessage({ type: 'scan', handles });
            else updateStatus();
          };
          const scheduleScan = () => {
            if (scanTimer) return;
            scanTimer = setTimeout(scan, 220);
          };
          new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true });
          updateStatus();
          scheduleScan();
        })();
        """
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
