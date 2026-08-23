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

    func testZenMuxMarkdownNormalizerRepairsQuotedStrongEmphasis() {
        XCTAssertEqual(
            ZenMuxMarkdownNormalizer.normalize(#"This is **"important"**."#),
            #"This is "**important**"."#
        )
        XCTAssertEqual(
            ZenMuxMarkdownNormalizer.normalize("This is **“important”**."),
            "This is “**important**”."
        )
    }

    func testZenMuxMarkdownNormalizerSupportsMathAndChemistry() {
        XCTAssertEqual(
            ZenMuxMarkdownNormalizer.normalize(#"Inline $E=mc^2$ and \[x^2+y^2=z^2\]."#),
            #"Inline \(E=mc^2\) and $$x^2+y^2=z^2$$."#
        )
        XCTAssertEqual(
            ZenMuxMarkdownNormalizer.normalize(#"Reaction: \ce{2H2 + O2 -> 2H2O}."#),
            #"Reaction: \mathrm{2H_{2} + O_{2} \rightarrow 2H_{2}O}."#
        )
    }

    func testZenMuxMarkdownParserBuildsRichBlocks() {
        XCTAssertEqual(
            ZenMuxMarkdownParser.blocks(from: """
            ## Result

            **Bold** and `code`

            - First
            - Second

            $$
            E = mc^2
            $$
            """),
            [
                .heading(level: 2, content: "Result"),
                .paragraph("**Bold** and `code`"),
                .unorderedList(["First", "Second"]),
                .math("E = mc^2"),
            ]
        )
    }

    func testZenMuxMarkdownParserBuildsGitHubFlavoredTableBlocks() {
        XCTAssertEqual(
            ZenMuxMarkdownParser.blocks(from: """
            | Fund | Expense ratio | Return |
            | :--- | ---: | :---: |
            | **VOO** | 0.03% | +21.9% |
            | SPY | 0.09% | +21.7% |
            """),
            [
                .table(.init(
                    headers: ["Fund", "Expense ratio", "Return"],
                    rows: [
                        ["**VOO**", "0.03%", "+21.9%"],
                        ["SPY", "0.09%", "+21.7%"],
                    ]
                )),
            ]
        )
    }

    func testZenMuxMarkdownParserPreservesEscapedPipesInsideTables() {
        XCTAssertEqual(
            ZenMuxMarkdownParser.blocks(from: """
            Symbol | Meaning
            --- | ---
            `A\\|B` | Alternatives
            """),
            [
                .table(.init(
                    headers: ["Symbol", "Meaning"],
                    rows: [["`A|B`", "Alternatives"]]
                )),
            ]
        )
    }

    func testZenMuxMarkdownNormalizerSupportsFencedLatex() {
        XCTAssertEqual(
            ZenMuxMarkdownNormalizer.normalize("""
            ```latex
            \\sin x = x - \\frac{x^3}{3!} + \\frac{x^5}{5!} - \\cdots
            ```
            """),
            """
            $$
            \\sin x = x - \\frac{x^3}{3!} + \\frac{x^5}{5!} - \\cdots
            $$
            """
        )
    }

    func testZenMuxLatexNormalizerRepairsCommonModelOutput() {
        XCTAssertEqual(
            ZenMuxLatexNormalizer.normalize("""
            \\begin{equation*}
            \\operatorname{argmax}_{x} \\dfrac{x}{2} \\tag{1}
            \\end{equation*}
            """),
            "\\mathrm{argmax}_{x} \\frac{x}{2}"
        )
        XCTAssertEqual(
            ZenMuxLatexNormalizer.normalize("""
            \\begin{align*}
            y &= x^2 \\\\
            z &= x^3
            \\end{align*}
            """),
            """
            \\begin{aligned}
            y &= x^2 \\\\
            z &= x^3
            \\end{aligned}
            """
        )
    }

    @MainActor
    func testZenMuxMathRendererHandlesTaylorAndLimitFormulas() {
        for formula in [
            #"\sin x = x - \frac{x^3}{3!} + \frac{x^5}{5!} - \cdots"#,
            #"\lim_{x \to 0} \frac{\sin x}{x} = 1"#,
            #"\begin{equation*}\operatorname{argmax}_{x} \dfrac{x}{2}\end{equation*}"#,
        ] {
            XCTAssertNotNil(
                ZenMuxMathRenderer.render(
                    latex: formula,
                    fontSize: 15,
                    textColor: .labelColor,
                    labelMode: .display
                ),
                formula
            )
        }
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
