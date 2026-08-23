// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class GuestModeUITests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "GuestModeUITests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testGuestModeDisablesBuiltInAIWhilePreservingZenMuxAndNewTabBehavior() {
        let newTabPageKey = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue

        for openNewTabPage in [false, true] {
            defaults.set(true, forKey: GuestModePreferences.aiEnabledKey)
            for key in GuestModePreferences.builtInAIKeys {
                defaults.set(true, forKey: key)
            }
            defaults.set(openNewTabPage, forKey: newTabPageKey)

            GuestModePreferences.disableBuiltInAI(defaults: defaults)

            XCTAssertTrue(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
            for key in GuestModePreferences.builtInAIKeys {
                XCTAssertFalse(defaults.bool(forKey: key))
            }
            XCTAssertEqual(defaults.bool(forKey: newTabPageKey), openNewTabPage)
        }
    }

    func testGuestModeDoesNotCreateZenMuxOrNewTabPreferences() {
        let newTabPageKey = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue

        GuestModePreferences.disableBuiltInAI(defaults: defaults)

        let domain = defaults.persistentDomain(forName: defaultsSuiteName)
        XCTAssertNil(domain?[GuestModePreferences.aiEnabledKey])
        XCTAssertNil(domain?[newTabPageKey])
    }

    func testDisablingBuiltInGuestAIIsIdempotent() {
        GuestModePreferences.disableBuiltInAI(defaults: defaults)
        GuestModePreferences.disableBuiltInAI(defaults: defaults)

        for key in GuestModePreferences.builtInAIKeys {
            XCTAssertFalse(defaults.bool(forKey: key))
        }
    }

    func testPostLoginAIEnableIntentIsConsumedOnce() {
        var intent = PostLoginAIEnableIntent()

        intent.request()

        XCTAssertTrue(intent.isPending)
        XCTAssertTrue(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: true)
        )
        XCTAssertTrue(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: true)
        )
    }

    func testPostLoginAIEnableIntentCanBeCancelled() {
        var intent = PostLoginAIEnableIntent()
        defaults.set(false, forKey: GuestModePreferences.aiEnabledKey)

        intent.request()
        intent.cancel()

        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: true)
        )
        XCTAssertFalse(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
    }

    func testUnsupportedBuildCannotEnableAIFromPostLoginIntent() {
        var intent = PostLoginAIEnableIntent()
        defaults.set(true, forKey: GuestModePreferences.aiEnabledKey)
        intent.request()

        XCTAssertFalse(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: false)
        )
        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
    }

    func testGuestModeExitTriggerSurvivesUntilSuccessfulConsumption() {
        var context = GuestModeExitAnalyticsContext()

        context.request(.aiSetting)

        XCTAssertNil(context.consume(startedInGuestMode: false))
        XCTAssertEqual(context.pendingTrigger, .aiSetting)
        XCTAssertEqual(
            context.consume(startedInGuestMode: true)?.rawValue,
            "ai_setting"
        )
        XCTAssertNil(context.pendingTrigger)
    }

    func testGuestModeExitTriggerCanBeCancelled() {
        var context = GuestModeExitAnalyticsContext()

        context.request(.accountSetting)
        context.cancel()

        XCTAssertNil(context.pendingTrigger)
        XCTAssertNil(context.consume(startedInGuestMode: true))
    }

    @MainActor
    func testCompletingGuestOOBESetsComfortableLayout() {
        let layoutModeKey = PhiPreferences.GeneralSettings.layoutModeKey
        let originalLayoutMode = UserDefaults.standard.string(forKey: layoutModeKey)
        defer {
            if let originalLayoutMode {
                UserDefaults.standard.set(originalLayoutMode, forKey: layoutModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: layoutModeKey)
            }
        }

        PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)

        let controller = OnboardingWindowController()
        controller.completeGuestOOBE()

        XCTAssertEqual(
            PhiPreferences.GeneralSettings.loadLayoutMode(),
            .comfortable
        )
    }

    func testLoginRequiredPolicyFailsClosedForStaleEnabledGuestAIState() {
        for surface in [
            LoginRequiredSurface.newTabPage,
            .aiChat
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: true,
                    supportsAuthentication: true
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: false,
                    supportsAuthentication: true
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: false,
                    isPhiAIEnabled: true,
                    supportsAuthentication: true
                )
            )
        }
    }

    func testLoginRequiredPolicyGatesEveryGuestAccountSurface() {
        for surface in [
            LoginRequiredSurface.browserMemory,
            LoginRequiredSurface.connectors,
            .imChannels
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: false,
                    supportsAuthentication: true
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: false,
                    isPhiAIEnabled: true,
                    supportsAuthentication: true
                )
            )
        }
    }

    func testLoginRequiredPolicyIsDisabledWhenBuildHasNoAuthentication() {
        for surface in [
            LoginRequiredSurface.newTabPage,
            .aiChat,
            .browserMemory,
            .connectors,
            .imChannels,
        ] {
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: true,
                    supportsAuthentication: false
                )
            )
        }
    }

    func testZenMuxMarkdownParserPreservesInlineFormattingInsideOrderedLists() {
        let blocks = ZenMuxMarkdownParser.blocks(from: """
        Summary with **bold text**.

        1. **First item**: details
        2. Second item
        """)

        XCTAssertEqual(
            blocks,
            [
                .paragraph("Summary with **bold text**."),
                .orderedList([
                    .init(marker: 1, content: "**First item**: details"),
                    .init(marker: 2, content: "Second item"),
                ]),
            ]
        )
    }

    func testZenMuxMarkdownParserHandlesHeadingsQuotesAndCodeBlocks() {
        let blocks = ZenMuxMarkdownParser.blocks(from: """
        ## Details
        > Important context
        ```swift
        let answer = 42
        ```
        """)

        XCTAssertEqual(
            blocks,
            [
                .heading(level: 2, content: "Details"),
                .quote("Important context"),
                .code("let answer = 42"),
            ]
        )
    }

    @MainActor
    func testEventBlockingBackgroundCanPassClicksToUnderlyingWebContent() {
        let view = EventBlockBgView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.shouldPassThroughHitTest = { point in
            point.x > 100
        }

        XCTAssertNotNil(view.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertNil(view.hitTest(NSPoint(x: 150, y: 50)))
    }

    func testBrowserMemoryURLClassificationAcceptsInternalAliasesOnly() {
        for url in [
            "chrome://memory/memory.html",
            "phi://memory/memory.html",
            "phi://MEMORY/dashboard?view=recent"
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.isBrowserMemoryURL(url)
            )
        }

        for url in [
            "https://memory/memory.html",
            "phi://memory-settings/memory.html",
            "phi://conversation/memory.html",
            nil
        ] {
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.isBrowserMemoryURL(url)
            )
        }
    }

    @MainActor
    func testContinueAsGuestInvokesLifecycleCallback() {
        let controller = LoginViewController()
        controller.isGuestModeActiveProvider = { false }
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        XCTAssertTrue(controller.shouldShowContinueAsGuest)
        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor
    func testGuestLoginPresentationHidesAndBlocksContinueAsGuest() {
        let controller = LoginViewController()
        controller.isGuestModeActiveProvider = { true }
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        XCTAssertFalse(controller.shouldShowContinueAsGuest)
        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 0)
    }

    @MainActor
    func testGuestMigrationRecoveryHidesAndBlocksContinueAsGuest() {
        let controller = LoginViewController()
        controller.presentationMode = .guestMigrationRecovery
        controller.isGuestModeActiveProvider = { false }
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        XCTAssertFalse(controller.shouldShowContinueAsGuest)
        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 0)
    }

    func testBrowserKeyboardShortcutsRemainAvailableToCEFChildWindows() {
        XCTAssertEqual(
            MainBrowserWindowController.browserKeyboardShortcut(
                character: "t",
                modifiers: .command
            ),
            .newTab
        )
        XCTAssertEqual(
            MainBrowserWindowController.browserKeyboardShortcut(
                character: "L",
                modifiers: .command
            ),
            .focusLocation
        )
        XCTAssertNil(
            MainBrowserWindowController.browserKeyboardShortcut(
                character: "t",
                modifiers: [.command, .shift]
            )
        )
    }
}
