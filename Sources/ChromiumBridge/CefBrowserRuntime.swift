// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CefKit

struct BrowserAutomationAction: Equatable {
    enum Kind: String {
        case inspectPage = "inspect_page"
        case navigate
        case click
        case typeText = "type_text"
        case pressKey = "press_key"
        case waitForElement = "wait_for_element"
        case inspectVisualPage = "inspect_visual_page"
        case visualClick = "visual_click"
        case scroll
        case goBack = "go_back"
        case reload
        case openTab = "open_tab"
    }

    let kind: Kind
    var index: Int?
    var ref: String?
    var selector: String?
    var matchIndex: Int?
    var text: String?
    var key: String?
    var url: URL?
    var pixels: Int?
    var milliseconds: Int?
    var x: Int?
    var y: Int?
}

enum BrowserAutomationVerificationPolicy {
    static let requiredStableInspectionCount = 2

    static func requiresPostActionInspection(_ kind: BrowserAutomationAction.Kind) -> Bool {
        switch kind {
        case .navigate, .click, .typeText, .pressKey, .visualClick, .scroll, .goBack, .reload, .openTab:
            return true
        case .inspectPage, .waitForElement, .inspectVisualPage:
            return false
        }
    }

    static func verifiesPageState(_ kind: BrowserAutomationAction.Kind) -> Bool {
        kind == .inspectPage || kind == .waitForElement
    }
}

enum CefDisabledFeaturePolicy {
    private static let appRequiredFeatures = ["UserAgentClientHint"]

    static func mergingCEFDefaults(_ existingValue: String?) -> String {
        var seen = Set<String>()
        return ((existingValue?.split(separator: ",").map(String.init) ?? []) + appRequiredFeatures)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ",")
    }
}

enum CefWebRTCPrivacyPolicy {
    static let commandLineSwitch = "webrtc-ip-handling-policy"
    static let requiredValue = "disable_non_proxied_udp"

    static func apply(to commandLine: CefCommandLine) {
        // Keep WebRTC available while preventing it from bypassing a configured
        // proxy or VPN with direct UDP candidates. Appending here overrides any
        // weaker value supplied on the process command line.
        commandLine.appendSwitch(commandLineSwitch, value: requiredValue)
    }
}

struct BrowserAutomationPoint: Equatable {
    static let normalizedMaximum = 1_000

    let x: Int
    let y: Int

    init?(x: Int?, y: Int?) {
        guard let x, let y,
              (0...Self.normalizedMaximum).contains(x),
              (0...Self.normalizedMaximum).contains(y) else {
            return nil
        }
        self.x = x
        self.y = y
    }

    func point(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * CGFloat(x) / CGFloat(Self.normalizedMaximum),
            y: size.height * CGFloat(y) / CGFloat(Self.normalizedMaximum)
        )
    }
}

struct BrowserAutomationTarget: Equatable {
    static let maximumRefLength = 128
    static let maximumSelectorLength = 1_000
    static let maximumMatchIndex = 50

    let index: Int?
    let ref: String?
    let selector: String?
    let matchIndex: Int

    init(index: Int?, ref: String?, selector: String?, matchIndex: Int?) {
        self.index = index.flatMap { $0 >= 0 ? $0 : nil }
        self.ref = Self.normalizedRef(ref)
        self.selector = Self.normalizedSelector(selector)
        self.matchIndex = max(0, min(Self.maximumMatchIndex, matchIndex ?? 0))
    }

    init(action: BrowserAutomationAction) {
        self.init(
            index: action.index,
            ref: action.ref,
            selector: action.selector,
            matchIndex: action.matchIndex
        )
    }

    var isSpecified: Bool {
        index != nil || ref != nil || selector != nil
    }

    func javaScriptResolver() -> String? {
        guard isSpecified,
              let encodedRef = Self.encodedJavaScriptValue(ref),
              let encodedSelector = Self.encodedJavaScriptValue(selector) else {
            return nil
        }
        let encodedIndex = index.map(String.init) ?? "null"
        return """
        const targetRef = \(encodedRef);
        const targetSelector = \(encodedSelector);
        const targetIndex = \(encodedIndex);
        const targetMatchIndex = \(matchIndex);
        let targetError = null;
        let element = null;
        if (targetRef) {
          element = Array.from(document.querySelectorAll('[data-astra-ai-ref]')).find(
            (candidate) => candidate.getAttribute('data-astra-ai-ref') === targetRef
          ) || null;
        }
        if (!element && targetSelector) {
          try {
            element = document.querySelectorAll(targetSelector)[targetMatchIndex] || null;
          } catch (_) {
            targetError = 'The CSS selector is invalid.';
          }
        }
        if (!element && Number.isInteger(targetIndex)) {
          element = document.querySelector(`[data-astra-ai-index="${targetIndex}"]`);
        }
        """
    }

    private static func normalizedRef(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumRefLength else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    private static func normalizedSelector(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumSelectorLength,
              !value.contains("\0") else {
            return nil
        }
        return value
    }

    private static func encodedJavaScriptValue(_ value: String?) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct BrowserAutomationResult: Equatable {
    let succeeded: Bool
    let message: String
    var imageDataURL: String? = nil
}

/// A normal CEF browser window stays alive when the user presses the title-bar
/// close button. CEF has no Chromium session bridge to rebuild an in-process
/// closed window, so ordering it out is what preserves the exact tabs, page
/// history, scroll position, and form state for the next Dock activation.
/// Programmatic `close()` calls still perform a real teardown.
@MainActor
private final class CefBrowserWindow: NSWindow {
    var preservesStateOnUserClose = false

    func configureStatePreservingClose() {
        preservesStateOnUserClose = true
        standardWindowButton(.closeButton)?.target = self
        standardWindowButton(.closeButton)?.action = #selector(orderOutPreservingState(_:))
    }

    override func performClose(_ sender: Any?) {
        guard preservesStateOnUserClose, sender != nil else {
            super.performClose(sender)
            return
        }
        orderOut(sender)
    }

    @objc private func orderOutPreservingState(_ sender: Any?) {
        AppLogInfo("[CEF] preserving the browser window state on user close")
        orderOut(sender)
    }
}

@MainActor
@objc final class CefBrowserRuntime: NSObject {
    private struct PageContextPayload: Codable, Sendable {
        let requestID: String
        let token: String
        let text: String
    }

    private struct PageContextResponse: Codable, Sendable {
        let accepted: Bool
    }

    private struct PendingPageContext {
        let token: String
        let continuation: CheckedContinuation<String?, Never>
    }

    private struct AutomationPayload: Codable, Sendable {
        let requestID: String
        let token: String
        let result: String
    }

    private struct AutomationResponse: Codable, Sendable {
        let accepted: Bool
    }

    private struct WebCredentialPayload: Codable, Sendable {
        let action: String
        let token: String
        let origin: String
        let username: String?
        let password: String?
    }

    private struct WebCredentialResponse: Codable, Sendable {
        let accepted: Bool
    }

    private final class WeakCredentialHandler {
        weak var value: CefWebContentWrapper?

        init(_ value: CefWebContentWrapper) {
            self.value = value
        }
    }

    private struct PendingAutomation {
        let token: String
        let continuation: CheckedContinuation<String?, Never>
    }

    @objc static let shared = CefBrowserRuntime()

    private static var retainedAppController: AppController?
    private var nextWindowId = 1
    private var profiles: [String: CefProfile] = [:]
    private var pendingPageContext: [String: PendingPageContext] = [:]
    private var pageContextTimeouts: [String: DispatchWorkItem] = [:]
    private var pendingAutomation: [String: PendingAutomation] = [:]
    private var automationTimeouts: [String: DispatchWorkItem] = [:]
    private var credentialHandlers: [String: WeakCredentialHandler] = [:]

    @objc static func bootstrapApplication() -> Bool {
        do {
            var configuration = CefConfiguration.default
            let root: URL
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || CommandLine.arguments.contains("--cef-smoke-test") {
                // A unique CEF data directory keeps tests isolated from a
                // running Astra Browser process and the user's profile.
                root = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "AstraBrowserTests-\(ProcessInfo.processInfo.processIdentifier)",
                        isDirectory: true
                    )
            } else {
                root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.phibrowser.Phi", isDirectory: true)
                    .appendingPathComponent("CEF", isDirectory: true)
            }
            configuration.rootCachePath = root
            configuration.cachePath = root
            configuration.persistSessionCookies = true
            configuration.defaultRuntimeStyle = .chrome
            configuration.userAgentProduct = SupportedBrowserUserAgent.chromiumProduct
            // Gmail rejects unbranded Chromium Client Hints. Prefer the UA
            // string, which reports a current Chrome product token. Preserve
            // CEF's compatibility exclusions when adding this feature.
            configuration.onBeforeCommandLineProcessing = { commandLine in
                let disabledFeatures = CefDisabledFeaturePolicy.mergingCEFDefaults(
                    commandLine.switchValue("disable-features")
                )
                commandLine.appendSwitch("disable-features", value: disabledFeatures)
                CefWebRTCPrivacyPolicy.apply(to: commandLine)
            }
            // Some CDN edges reset multiplexed image streams while still serving
            // the same resources correctly over HTTP/1.1. Prefer the reliable
            // transport so valid images and media do not remain broken.
            configuration.extraCommandLineSwitches["disable-http2"] = nil
            try CefRuntime.shared.initialize(configuration: configuration)
            shared.registerPageContextBridge()
            shared.registerAutomationBridge()
            shared.registerWebCredentialBridge()

            let controller = AppController()
            retainedAppController = controller
            NSApp.delegate = controller
            controller.startObservingMainMenu()
            return true
        } catch {
            AppLogError("CefSwift initialization failed: \(error.localizedDescription)")
            return false
        }
    }

    func applicationDidFinishLaunching() {
        guard MainBrowserWindowControllersManager.shared.activeWindowController == nil else { return }
        let initialURL = CommandLine.arguments
            .first(where: { $0.hasPrefix("--astra-initial-url=") })?
            .dropFirst("--astra-initial-url=".count)
        openBrowserWindow(initialURL: initialURL.map(String.init) ?? "chrome://newtab")
    }

    func openBrowserWindow(initialURL: String = "chrome://newtab") {
        let profileId: String
        if CommandLine.arguments.contains("--cef-smoke-test"),
           let requestedProfile = CommandLine.arguments
            .first(where: { $0.hasPrefix("--astra-smoke-profile=") })?
            .dropFirst("--astra-smoke-profile=".count),
           !requestedProfile.isEmpty {
            profileId = String(requestedProfile)
        } else {
            profileId = LocalStore.defaultProfileId
        }
        let spaceId = LocalStore.defaultSpaceId
        let slot = SpaceManager.shared.createSlot(initialSpaceId: spaceId)
        _ = spawnWindow(
            in: slot,
            spaceId: spaceId,
            profileId: profileId,
            isIncognito: false,
            initialURLs: [initialURL],
            inheritedFrame: nil,
            hidden: false
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Surfaces the most recently active normal CEF window after the user hid
    /// every browser window with the title-bar close button. The controller,
    /// tabs, and live web contents never changed, so this restores the exact
    /// in-memory page state rather than reconstructing URLs.
    @discardableResult
    func reopenStatePreservedWindowIfNeeded() -> Bool {
        let manager = MainBrowserWindowControllersManager.shared
        let controllers = manager.getAllWindows().filter { controller in
            controller.browserType == .normal
                && controller.window is CefBrowserWindow
        }
        guard !controllers.isEmpty,
              !controllers.contains(where: { $0.window?.isVisible == true }),
              let controller = controllers.first(where: {
                  $0 === manager.activeWindowController
              }) ?? controllers.first,
              let window = controller.window as? CefBrowserWindow,
              window.preservesStateOnUserClose else { return false }
        AppLogInfo("[CEF] reopening the state-preserved browser window")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @discardableResult
    func spawnWindow(
        in slot: SpaceWindowSlot,
        spaceId: String,
        profileId: String,
        isIncognito: Bool,
        initialURLs: [String],
        inheritedFrame: NSRect?,
        hidden: Bool
    ) -> Int {
        let windowId = nextWindowId
        nextWindowId += 1
        let contentRect = inheritedFrame
            ?? NSRect(origin: .zero, size: MainBrowserWindowController.defaultWindowSize)
        let window = CefBrowserWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        if !isIncognito {
            window.configureStatePreservingClose()
        }
        if let inheritedFrame {
            window.setFrame(inheritedFrame, display: false)
        } else {
            window.center()
        }
        if hidden {
            window.orderOut(nil)
        }
        let resolvedProfileId = profileId.isEmpty ? LocalStore.defaultProfileId : profileId
        let controller = MainBrowserWindowController(
            window: window,
            windowId: windowId,
            browserType: isIncognito ? .incognitoSpace : .normal,
            profileId: resolvedProfileId,
            spaceId: spaceId,
            slot: slot
        )
        let urls = initialURLs.isEmpty ? ["chrome://newtab"] : initialURLs
        for (index, url) in urls.enumerated() {
            createTab(
                in: controller.browserState,
                urlString: url,
                customGuid: nil,
                focusAfterCreate: index == 0
            )
        }
        if !hidden {
            if inheritedFrame == nil {
                controller.restoreAndShowWindow()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return windowId
    }

    func createTab(
        in state: BrowserState,
        urlString: String,
        customGuid: String?,
        focusAfterCreate: Bool
    ) {
        let profile = profile(for: state.profileId, incognito: state.isIncognito)
        let wrapper = CefWebContentWrapper(
            urlString: urlString,
            profile: profile,
            profileId: state.profileId,
            allowsCredentialStorage: !state.isIncognito,
            downloadsManager: state.downloadsManager
        )
        let tab = Tab(
            url: urlString,
            isActive: focusAfterCreate,
            index: state.tabs.count,
            title: urlString.isNTP ? "New Tab" : "",
            webContentView: wrapper,
            customGuid: customGuid,
            windowId: state.windowId,
            profileId: state.profileId
        )
        if urlString.isNTP {
            tab.nativeNTPIsIncognito = state.isIncognito
            tab.usesNativeNTP = true
        }
        wrapper.onActivate = { [weak state, weak tab] in
            guard let state, let tab else { return }
            state.focuseTab(tab)
        }
        wrapper.onClose = { [weak self, weak state, weak tab] in
            guard let self, let state, let tab else { return }
            self.finishClosing(tab: tab, in: state)
        }
        wrapper.onMove = { [weak state, weak tab] index, shouldSelect in
            guard let state, let tab,
                  let oldIndex = state.normalTabs.firstIndex(where: { $0.guid == tab.guid }) else { return }
            state.moveNormalTabLocally(from: oldIndex, to: index)
            if shouldSelect { state.focuseTab(tab) }
        }
        wrapper.onOpenURLInNewTab = { [weak self, weak state] url, focus in
            guard let self, let state else { return }
            self.createTab(in: state, urlString: url.absoluteString, customGuid: nil, focusAfterCreate: focus)
        }

        state.handleNewTabFromChromium(tab)
        if focusAfterCreate {
            state.focuseTab(tab)
        }
    }

    func close(tab: Tab, in state: BrowserState) {
        guard let wrapper = tab.webContentWrapper as? CefWebContentWrapper else { return }
        wrapper.close()
    }

    private func finishClosing(tab: Tab, in state: BrowserState) {
        guard state.tabs.contains(where: { $0.guid == tab.guid }) else { return }
        let visibleTabs = state.normalTabs
        let oldIndex = visibleTabs.firstIndex(where: { $0.guid == tab.guid }) ?? 0
        state.closeTab(tab.guid)
        if state.tabs.isEmpty {
            state.windowController?.window?.close()
            return
        }
        if tab.isActive {
            let remaining = state.normalTabs
            let nextIndex = min(oldIndex, max(0, remaining.count - 1))
            if remaining.indices.contains(nextIndex) {
                state.focuseTab(remaining[nextIndex])
            }
        }
    }

    private func profile(for profileId: String, incognito: Bool) -> CefProfile {
        if incognito {
            let key = "incognito:\(profileId)"
            if let profile = profiles[key] { return profile }
            let profile = CefProfile.incognito()
            profiles[key] = profile
            return profile
        }
        if profileId == LocalStore.defaultProfileId {
            if let profile = profiles[profileId] { return profile }
            let profile = CefProfile.default
            profiles[profileId] = profile
            return profile
        }
        if let profile = profiles[profileId] { return profile }
        let profile = CefProfile.persistent(name: profileId)
        profiles[profileId] = profile
        return profile
    }

    private func registerPageContextBridge() {
        CefRuntime.shared.bridge.register("phiPageContext") {
            (payload: PageContextPayload) async -> PageContextResponse in
            await MainActor.run {
                CefBrowserRuntime.shared.receivePageContext(payload)
            }
            return PageContextResponse(accepted: true)
        }
    }

    private func registerAutomationBridge() {
        CefRuntime.shared.bridge.register("astraBrowserAutomation") {
            (payload: AutomationPayload) async -> AutomationResponse in
            await MainActor.run {
                CefBrowserRuntime.shared.receiveAutomation(payload)
            }
            return AutomationResponse(accepted: true)
        }
    }

    private func registerWebCredentialBridge() {
        CefRuntime.shared.bridge.register("astraWebCredential") {
            (payload: WebCredentialPayload) async -> WebCredentialResponse in
            let accepted = await MainActor.run {
                CefBrowserRuntime.shared.receiveWebCredential(payload)
            }
            return WebCredentialResponse(accepted: accepted)
        }
    }

    func registerCredentialHandler(token: String, handler: CefWebContentWrapper) {
        credentialHandlers[token] = WeakCredentialHandler(handler)
    }

    func unregisterCredentialHandler(token: String) {
        credentialHandlers[token] = nil
    }

    private func receiveWebCredential(_ payload: WebCredentialPayload) -> Bool {
        guard let handler = credentialHandlers[payload.token]?.value else {
            credentialHandlers[payload.token] = nil
            return false
        }
        handler.handleWebCredentialRequest(
            action: payload.action,
            origin: payload.origin,
            username: payload.username,
            password: payload.password
        )
        return true
    }

    func requestPageContent(browser: CefBrowser, token: String) async -> String? {
        let requestID = UUID().uuidString
        let script = """
        (async function () {
          const root = document.querySelector('main, [role="main"], article') || document.body;
          const normalize = (value) => (value || '').replace(/\\s+/g, ' ').trim();
          const semantic = [];
          if (root) {
            const nodes = root.querySelectorAll(
              '[data-testid="User-Name"], [data-testid="tweetText"], time, ' +
              'h1, h2, h3, [role="heading"], article a[href], article img[alt]'
            );
            for (let index = 0; index < nodes.length && semantic.length < 180; index += 1) {
              const node = nodes[index];
              const value = normalize(
                node.matches('img[alt]') ? node.getAttribute('alt') : node.textContent
              ).slice(0, 500);
              if (value && semantic[semantic.length - 1] !== value) semantic.push(value);
            }
          }
          const raw = normalize(root ? root.textContent : '');
          const text = `${semantic.join('\\n')}\\n${raw}`.trim().slice(0, 60000);
          if (window.cefSwift && window.cefSwift.invoke) {
            await window.cefSwift.invoke('phiPageContext', {
              requestID: '\(requestID)',
              token: '\(token)',
              text: text
            });
          }
        })();
        """
        return await withCheckedContinuation { continuation in
            pendingPageContext[requestID] = PendingPageContext(
                token: token,
                continuation: continuation
            )
            let timeout = DispatchWorkItem { [weak self] in
                guard let pending = self?.pendingPageContext.removeValue(forKey: requestID) else { return }
                self?.pageContextTimeouts[requestID] = nil
                pending.continuation.resume(returning: nil)
            }
            pageContextTimeouts[requestID] = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            browser.executeJavaScript(script)
        }
    }

    private func receivePageContext(_ payload: PageContextPayload) {
        guard let pending = pendingPageContext[payload.requestID],
              pending.token == payload.token else { return }
        pendingPageContext[payload.requestID] = nil
        pageContextTimeouts.removeValue(forKey: payload.requestID)?.cancel()
        let normalized = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        pending.continuation.resume(returning: normalized.isEmpty ? nil : String(normalized.prefix(60_000)))
    }

    func requestAutomation(
        browser: CefBrowser,
        token: String,
        operation: String,
        timeout: TimeInterval = 3.5
    ) async -> String? {
        let requestID = UUID().uuidString
        let script = """
        (async function () {
          let result;
          try {
            result = await (async function () { \(operation) })();
          } catch (error) {
            result = JSON.stringify({ ok: false, message: String(error && error.message ? error.message : error) });
          }
          if (typeof result !== 'string') result = JSON.stringify(result);
          if (window.cefSwift && window.cefSwift.invoke) {
            await window.cefSwift.invoke('astraBrowserAutomation', {
              requestID: '\(requestID)',
              token: '\(token)',
              result: result.slice(0, 50000)
            });
          }
        })();
        """
        return await withCheckedContinuation { continuation in
            pendingAutomation[requestID] = PendingAutomation(
                token: token,
                continuation: continuation
            )
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let pending = self?.pendingAutomation.removeValue(forKey: requestID) else { return }
                self?.automationTimeouts[requestID] = nil
                pending.continuation.resume(returning: nil)
            }
            automationTimeouts[requestID] = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            browser.executeJavaScript(script)
        }
    }

    private func receiveAutomation(_ payload: AutomationPayload) {
        guard let pending = pendingAutomation[payload.requestID],
              pending.token == payload.token else { return }
        pendingAutomation[payload.requestID] = nil
        automationTimeouts.removeValue(forKey: payload.requestID)?.cancel()
        pending.continuation.resume(returning: payload.result)
    }
}
