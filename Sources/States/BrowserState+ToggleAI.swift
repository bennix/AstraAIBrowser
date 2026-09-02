// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

enum XBookmarkDigestState: Equatable {
    case inactive
    case collecting(count: Int)
    case summarizing(count: Int)
    case completed(count: Int)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .collecting, .summarizing:
            return true
        case .inactive, .completed, .failed:
            return false
        }
    }
}

enum XBookmarkDigestError: LocalizedError {
    case unavailablePage
    case noBookmarks
    case timelineFailed
    case collectionLimitReached
    case conversationBusy

    var errorDescription: String? {
        switch self {
        case .unavailablePage:
            return NSLocalizedString(
                "xBookmarks.error.unavailablePage",
                value: "Open the signed-in X bookmarks page before starting.",
                comment: "X bookmark digest - Error shown when collection is started outside the supported bookmarks page"
            )
        case .noBookmarks:
            return NSLocalizedString(
                "xBookmarks.error.noBookmarks",
                value: "No bookmark posts were found. Check that X is signed in and the bookmarks timeline is visible.",
                comment: "X bookmark digest - Error shown when the automatic collector cannot find any bookmark posts"
            )
        case .timelineFailed:
            return NSLocalizedString(
                "xBookmarks.error.timelineFailed",
                value: "X stopped loading the bookmarks timeline. Retry after the page recovers.",
                comment: "X bookmark digest - Error shown when X displays a timeline loading failure during collection"
            )
        case .collectionLimitReached:
            return NSLocalizedString(
                "xBookmarks.error.collectionLimitReached",
                value: "Collection stopped before the end of the bookmarks timeline could be verified.",
                comment: "X bookmark digest - Error shown when the collector safety limit is reached before timeline completion"
            )
        case .conversationBusy:
            return NSLocalizedString(
                "xBookmarks.error.conversationBusy",
                value: "Wait for the current ZenMux response to finish, then try again.",
                comment: "X bookmark digest - Error shown when the tab AI conversation is already generating a response"
            )
        }
    }
}

enum XBookmarkDigestPolicy {
    static let maximumCollectionPasses = 10_000
    static let requiredStableBottomPasses = 8
    static let maximumReadinessPasses = 60
    static let readinessPollMilliseconds = 500

    static func isXURL(_ rawValue: String?) -> Bool {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "x.com"
            || host.hasSuffix(".x.com")
            || host == "twitter.com"
            || host.hasSuffix(".twitter.com")
    }

    static func isBookmarksURL(_ rawValue: String?) -> Bool {
        guard isXURL(rawValue),
              let rawValue,
              let url = URL(string: rawValue) else { return false }
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "i/history" || path == "i/bookmarks" || path == "bookmarks"
    }

    static func bookmarksURL(for rawValue: String?) -> String? {
        guard isXURL(rawValue) else { return nil }
        return "https://x.com/i/history"
    }
}

struct XBookmarkDigestAccumulator {
    struct Update: Equatable {
        let newItemCount: Int
        let totalCount: Int
        let reachedEnd: Bool
    }

    private var valuesByID: [String: XBookmarkContent] = [:]
    private var orderedIDs: [String] = []
    private var lastScrollHeight: Double?
    private var stableBottomPasses = 0
    private let requiredStableBottomPasses: Int

    init(requiredStableBottomPasses: Int = XBookmarkDigestPolicy.requiredStableBottomPasses) {
        self.requiredStableBottomPasses = max(1, requiredStableBottomPasses)
    }

    var items: [XBookmarkContent] {
        orderedIDs.compactMap { valuesByID[$0] }
    }

    mutating func ingest(_ snapshot: XBookmarkPageSnapshot) -> Update {
        var newItemCount = 0
        for item in snapshot.items {
            if let existing = valuesByID[item.id] {
                if item.contentWeight > existing.contentWeight {
                    valuesByID[item.id] = item
                }
            } else {
                valuesByID[item.id] = item
                orderedIDs.append(item.id)
                newItemCount += 1
            }
        }

        let heightIsStable = lastScrollHeight.map {
            abs($0 - snapshot.scrollHeight) <= 4
        } ?? false
        if snapshot.isAtBottom,
           !snapshot.isLoading,
           snapshot.isTimelineReady,
           (!valuesByID.isEmpty || snapshot.isExplicitlyEmpty),
           !snapshot.hasTimelineError,
           newItemCount == 0,
           heightIsStable {
            stableBottomPasses += 1
        } else {
            stableBottomPasses = 0
        }
        lastScrollHeight = snapshot.scrollHeight

        return Update(
            newItemCount: newItemCount,
            totalCount: valuesByID.count,
            reachedEnd: stableBottomPasses >= requiredStableBottomPasses
        )
    }
}

enum XBookmarkDigestBatchPlanner {
    static func batches(
        for items: [XBookmarkContent],
        maximumItemCount: Int = 60,
        maximumCharacterCount: Int = 45_000
    ) -> [[XBookmarkContent]] {
        let itemLimit = max(1, maximumItemCount)
        let characterLimit = max(1, maximumCharacterCount)
        var result: [[XBookmarkContent]] = []
        var batch: [XBookmarkContent] = []
        var characterCount = 0

        for item in items {
            let itemCharacters = max(1, item.estimatedCharacterCount)
            if !batch.isEmpty,
               (batch.count >= itemLimit || characterCount + itemCharacters > characterLimit) {
                result.append(batch)
                batch = []
                characterCount = 0
            }
            batch.append(item)
            characterCount += itemCharacters
        }
        if !batch.isEmpty {
            result.append(batch)
        }
        return result
    }
}

extension BrowserState {
    static func shouldOfferYouTubeDigest(
        pageURL: String?,
        isAIEnabled: Bool,
        isIncognito: Bool,
        isOverviewActive: Bool,
        isChatAvailable: Bool
    ) -> Bool {
        isAIEnabled
            && !isIncognito
            && !isOverviewActive
            && isChatAvailable
            && APIClient.isYouTubeVideoURL(pageURL)
    }

    static func shouldOfferXBookmarkDigest(
        pageURL: String?,
        isAIEnabled: Bool,
        isIncognito: Bool,
        isOverviewActive: Bool,
        isChatAvailable: Bool
    ) -> Bool {
        isAIEnabled
            && !isIncognito
            && !isOverviewActive
            && isChatAvailable
            && XBookmarkDigestPolicy.isXURL(pageURL)
    }

    /// Collects the complete virtualized X bookmarks timeline without model
    /// involvement, then sends the accumulated post content through the
    /// existing ZenMux networking and chat path for classification.
    @MainActor
    func toggleXBookmarkDigest() {
        let aiEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
        guard let tab = focusingTab,
              Self.shouldOfferXBookmarkDigest(
                pageURL: tab.url,
                isAIEnabled: aiEnabled,
                isIncognito: isIncognito,
                isOverviewActive: groupOverviewState != nil,
                isChatAvailable: tab.aiChatEnabled
              ) else {
            NSSound.beep()
            return
        }

        if tab.xBookmarkDigestState.isRunning {
            tab.xBookmarkDigestTask?.cancel()
            tab.xBookmarkDigestTask = nil
            tab.xBookmarkDigestOperationID = nil
            tab.xBookmarkDigestState = .inactive
            return
        }

        if !XBookmarkDigestPolicy.isBookmarksURL(tab.url) {
            guard let bookmarksURL = XBookmarkDigestPolicy.bookmarksURL(for: tab.url),
                  let webContentWrapper = tab.webContentWrapper else {
                NSSound.beep()
                return
            }
            webContentWrapper.navigate(toURL: bookmarksURL)
            return
        }

        guard let provider = tab.webContentWrapper as? XBookmarkCollectionProviding else {
            tab.xBookmarkDigestState = .failed(XBookmarkDigestError.unavailablePage.localizedDescription)
            return
        }
        let session = zenMuxChatSession(for: tab)
        guard !session.isSending else {
            tab.xBookmarkDigestState = .failed(XBookmarkDigestError.conversationBusy.localizedDescription)
            return
        }
        guard ((try? ZenMuxCredentialStore.shared.loadAPIKey()) ?? nil) != nil else {
            tab.xBookmarkDigestState = .failed(ZenMuxAPIError.invalidCredential.localizedDescription)
            return
        }

        let operationID = UUID()
        tab.xBookmarkDigestOperationID = operationID
        tab.xBookmarkDigestState = .collecting(count: 0)
        tab.xBookmarkDigestTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.xBookmarkDigestOperationID == operationID {
                    tab.xBookmarkDigestTask = nil
                    tab.xBookmarkDigestOperationID = nil
                }
            }

            do {
                try await provider.prepareXBookmarkCollection()
                try await Task.sleep(for: .milliseconds(1_000))
                var accumulator = XBookmarkDigestAccumulator()
                var reachedEnd = false

                for _ in 0..<XBookmarkDigestPolicy.maximumCollectionPasses {
                    try Task.checkCancellation()
                    guard tab.xBookmarkDigestOperationID == operationID,
                          XBookmarkDigestPolicy.isBookmarksURL(tab.url) else {
                        throw CancellationError()
                    }
                    let snapshot = try await provider.collectXBookmarkPageSnapshot()
                    if snapshot.hasTimelineError {
                        throw XBookmarkDigestError.timelineFailed
                    }
                    let update = accumulator.ingest(snapshot)
                    tab.xBookmarkDigestState = .collecting(count: update.totalCount)
                    if update.reachedEnd {
                        reachedEnd = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(750))
                }

                guard reachedEnd else { throw XBookmarkDigestError.collectionLimitReached }
                let items = accumulator.items
                guard !items.isEmpty else { throw XBookmarkDigestError.noBookmarks }

                tab.xBookmarkDigestState = .summarizing(count: items.count)
                tab.updateFocusTarget(.aiChat)
                self.prepareAIChatSidebarOpen(trigger: .button)
                self.setAIChatCollapsed(for: tab, collapsed: false)
                session.requestFocus()
                let succeeded = await session.summarizeXBookmarks(items)
                try Task.checkCancellation()
                guard tab.xBookmarkDigestOperationID == operationID else { return }
                if succeeded {
                    tab.xBookmarkDigestState = .completed(count: items.count)
                } else {
                    tab.xBookmarkDigestState = .failed(
                        session.errorMessage ?? ZenMuxAPIError.emptyResponse.localizedDescription
                    )
                }
            } catch is CancellationError {
                if tab.xBookmarkDigestOperationID == operationID {
                    tab.xBookmarkDigestState = .inactive
                }
            } catch {
                if tab.xBookmarkDigestOperationID == operationID {
                    tab.xBookmarkDigestState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Opens the native AI sidebar and immediately creates a structured digest
    /// for the focused YouTube video. The existing ZenMux page-context path
    /// owns transcript retrieval and audiovisual fallback, so this entry does
    /// not introduce a second video-processing or credential stack.
    @MainActor
    func startYouTubeDigest() {
        let aiEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
        guard let tab = focusingTab,
              Self.shouldOfferYouTubeDigest(
                pageURL: tab.url,
                isAIEnabled: aiEnabled,
                isIncognito: isIncognito,
                isOverviewActive: groupOverviewState != nil,
                isChatAvailable: tab.aiChatEnabled
              ) else {
            NSSound.beep()
            return
        }

        let session = zenMuxChatSession(for: tab)
        session.draft = ZenMuxChatSession.youtubeDigestDraft()
        tab.updateFocusTarget(.aiChat)
        prepareAIChatSidebarOpen(trigger: .button)
        setAIChatCollapsed(for: tab, collapsed: false)
        session.requestFocus()

        guard !session.isSending,
              ((try? ZenMuxCredentialStore.shared.loadAPIKey()) ?? nil) != nil else {
            return
        }

        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            var context = ZenMuxPageContext(title: tab.title, url: tab.url)
            if let provider = tab.webContentWrapper as? PageContentProviding {
                context.pageContent = await provider.pageContentContext()
            }
            await session.send(
                pageContext: context,
                browserAutomation: { [weak tab] action in
                    guard let provider = tab?.webContentWrapper as? BrowserAutomationProviding else {
                        return BrowserAutomationResult(
                            succeeded: false,
                            message: "This tab does not provide browser automation."
                        )
                    }
                    return await provider.performBrowserAutomation(action)
                },
                googleSearch: { [weak self] query in
                    await self?.collectZenMuxGoogleSearchResults(query: query) ?? []
                }
            )
        }
    }

    func onAIEnabledChanged(_ enabled: Bool, sentinelOnLogin: Bool) {
        _ = sentinelOnLogin
        Task {
            await SentinelHelper.unregister()
        }
        // ZenMux is the only AI provider. Keep the legacy scheduled-agent
        // process stopped regardless of the native chat toggle.
        MainActor.assumeIsolated { SentinelWatchdog.shared.stop() }
        SentinelHelper.requestTerminationForBrowserUpdate()
        if !enabled {
            closeAllAIContent()
        }
    }

    /// Re-asserts the disabled half of the AI toggle as a window comes up.
    ///
    /// `updateAISettings` only reacts to an edge, and `lastPhiAIEnabled` is
    /// seeded from the preference the window is born with. Guest entry turns
    /// AI off before the first window materializes, so that edge lands with no
    /// BrowserState listening and the one created afterwards sees no change —
    /// leaving the Phi extensions loaded for the whole session.
    ///
    /// Only the disabled half needs re-asserting: `ExtensionsProxy::Init`
    /// already re-enables the Phi extensions when the Mac-side toggle is on.
    /// The side effects of `onAIEnabledChanged` (Sentinel teardown and AI
    /// content teardown) belong to the toggle's edge and are deliberately not
    /// repeated per window.
    ///
    /// Deferred one runloop turn: on the ordinary window path this runs inside
    /// `Browser::Create`, before the owning window controller finished
    /// construction and registered itself. Disabling extensions there would
    /// re-enter the Mac side with registry change events for a window that is
    /// not yet addressable.
    func syncPhiExtensionsIfAIDisabled() {
        // The ZenMux chat does not use the private AI extension. Do not toggle
        // the framework's extension bundle here because non-AI browser
        // features, including Reader View, have their own lifecycle in it.
    }

    /// Only called when AI is enabled.
    func updateSentinelRegistration(_ launchOnLogin: Bool) {
        MainActor.assumeIsolated {
            AuthenticatedSentinelSessionLifecycle.reconcile(
                aiEnabled:
                    PhiPreferences.AISettings.phiAIEnabled.loadValue(),
                launchOnLogin: launchOnLogin
            )
        }
    }

    func closeAllAIContent() {
        for tab in tabs {
            tab.toggleAIChat(true)
        }
        aiChatCollapsed = true

        let aiTabsSnapshot = aiChatTabs
        aiChatTabs.removeAll()
        removeAllZenMuxChatSessions()
        for (_, aiTab) in aiTabsSnapshot {
            aiTab.webContentWrapper?.close()
        }

        let conversationTabs = tabs.filter { tab in
            guard let url = tab.url else { return false }
            return url.hasPrefix("chrome://conversation") || url.hasPrefix("phi://conversation")
        }

        guard !conversationTabs.isEmpty else { return }

        let nonConversationCount = tabs.count - conversationTabs.count
        if nonConversationCount == 0 {
            createTab("chrome://newtab", focusAfterCreate: true)
        }

        for tab in conversationTabs {
            tab.webContentWrapper?.close()
        }
    }
}
