// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

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
