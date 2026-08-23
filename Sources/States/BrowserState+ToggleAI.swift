// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

extension BrowserState {
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
