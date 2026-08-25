// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CefKit
import CryptoKit
import WebKit

protocol PageContentProviding: AnyObject {
    @MainActor
    func pageContentContext() async -> String?
}

protocol BrowserAutomationProviding: AnyObject {
    @MainActor
    func performBrowserAutomation(_ action: BrowserAutomationAction) async -> BrowserAutomationResult
}

struct MediaDownloadCandidate: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case video
        case audio
    }

    let url: URL
    let title: String
    let kind: Kind
    let durationSeconds: Double?
}

protocol MediaSessionCookieProviding: AnyObject {
    @MainActor
    func mediaSessionCookies(for url: URL) async -> [HTTPCookie]

    @MainActor
    func mediaDownloadCandidates(for pageURL: URL) async -> [MediaDownloadCandidate]
}

enum BrowserAutomationInteractionPolicy {
    static func requiresConfirmation(controlType: String?) -> Bool {
        controlType?.lowercased() == "submit"
    }
}

enum BrowserWindowOpenPolicy {
    static func isIdentityProviderURL(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https",
              let host = url?.host?.lowercased() else { return false }
        if host == "accounts.youtube.com" || host.hasPrefix("accounts.google.") {
            return true
        }

        let path = url?.path.lowercased() ?? ""
        let isXIdentityHost = host == "x.com"
            || host.hasSuffix(".x.com")
            || host == "twitter.com"
            || host.hasSuffix(".twitter.com")
        guard isXIdentityHost else { return false }
        return path == "/i/oauth2/authorize"
            || path.hasPrefix("/i/oauth2/authorize/")
            || path == "/oauth/authorize"
            || path == "/oauth/authenticate"
    }

    static func action(for request: CefWindowOpenRequest) -> CefWindowOpenAction {
        // OAuth and identity-provider flows use a real popup plus window.opener
        // to deliver the authorization result back to the relying page. Moving
        // that popup into an unrelated app tab breaks the opener relationship
        // and causes sites to restart verification indefinitely.
        if !request.isSourceOffscreen,
           isIdentityProviderURL(request.targetURL) {
            return .allowNativePopup
        }
        return request.targetURL == nil ? .deny : .handled
    }

    static func shouldHandleNewTabInApp(for url: URL) -> Bool {
        !isIdentityProviderURL(url)
    }
}

enum WebResourceCompatibilityPolicy {
    static func permitsPageMutation(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host != nil else { return false }

        // Identity pages depend on an unmodified DOM and opener/postMessage
        // channel to return OAuth results to the relying site. Resource repair
        // must never rewrite executable elements inside those documents.
        if BrowserWindowOpenPolicy.isIdentityProviderURL(url) {
            return false
        }
        return true
    }
}

enum YouTubeAdPlaybackPolicy {
    static let adPlaybackRate = 8.0

    private static let supportedDomains = [
        "youtube.com",
        "youtube-nocookie.com",
    ]

    static func supports(host: String?) -> Bool {
        guard let host else { return false }
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return supportedDomains.contains {
            normalizedHost == $0 || normalizedHost.hasSuffix(".\($0)")
        }
    }

    static var javaScript: String {
        let domainList = supportedDomains
            .map { "'\($0)'" }
            .joined(separator: ", ")
        return """
        (function () {
          const supportedDomains = [\(domainList)];
          const hostname = location.hostname.toLowerCase().replace(/^\\.+|\\.+$/g, '');
          const isSupportedHost = supportedDomains.some(
            (domain) => hostname === domain || hostname.endsWith(`.${domain}`)
          );
          if (!isSupportedHost || window.__astraYouTubeAdPlaybackInstalled) return;
          window.__astraYouTubeAdPlaybackInstalled = true;

          const targetPlaybackRate = \(adPlaybackRate);
          let adIsActive = false;
          let contentPlaybackRate = 1;
          let contentDefaultPlaybackRate = 1;
          let adVideo = null;

          const currentVideo = () =>
            document.querySelector('.html5-main-video') || document.querySelector('video');
          const playerShowsAd = () => {
            const player = document.getElementById('movie_player') ||
              document.querySelector('.html5-video-player');
            return Boolean(player && (
              player.classList.contains('ad-showing') ||
              player.classList.contains('ad-interrupting')
            ));
          };
          const validRate = (value, fallback) =>
            Number.isFinite(value) && value > 0 ? value : fallback;
          const setRate = (video, playbackRate, defaultPlaybackRate = playbackRate) => {
            if (!video) return;
            if (video.defaultPlaybackRate !== defaultPlaybackRate) {
              video.defaultPlaybackRate = defaultPlaybackRate;
            }
            if (video.playbackRate !== playbackRate) video.playbackRate = playbackRate;
          };
          const updatePlaybackRate = () => {
            const video = currentVideo();
            const showingAd = playerShowsAd();

            if (showingAd) {
              if (!adIsActive) {
                contentPlaybackRate = validRate(video?.playbackRate, contentPlaybackRate);
                contentDefaultPlaybackRate = validRate(
                  video?.defaultPlaybackRate,
                  contentDefaultPlaybackRate
                );
              }
              adIsActive = true;
              adVideo = video;
              setRate(video, targetPlaybackRate);
              return;
            }

            if (adIsActive) {
              adIsActive = false;
              setRate(video || adVideo, contentPlaybackRate, contentDefaultPlaybackRate);
              adVideo = null;
              return;
            }

            if (video) {
              contentPlaybackRate = validRate(video.playbackRate, contentPlaybackRate);
              contentDefaultPlaybackRate = validRate(
                video.defaultPlaybackRate,
                contentDefaultPlaybackRate
              );
            }
          };
          const start = () => {
            document.addEventListener('ratechange', updatePlaybackRate, true);
            document.addEventListener('playing', updatePlaybackRate, true);
            document.addEventListener('loadedmetadata', updatePlaybackRate, true);
            document.addEventListener('visibilitychange', updatePlaybackRate, true);
            new MutationObserver(updatePlaybackRate).observe(document.documentElement, {
              subtree: true,
              childList: true,
              attributes: true,
              attributeFilter: ['class', 'src']
            });
            window.setInterval(updatePlaybackRate, 250);
            updatePlaybackRate();
          };
          if (document.documentElement) start();
          else document.addEventListener('DOMContentLoaded', start, { once: true });
        })();
        """
    }
}

enum SupportedBrowserUserAgent {
    static let chromiumProduct = "Chrome/148.0.7778.218"

    static var safariApplicationName: String {
        "Version/\(safariVersion) Safari/605.1.15"
    }

    static var safariCompatibleUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariApplicationName)"
    }

    static var safariVersion: String {
        let infoURL = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        if let info = NSDictionary(contentsOf: infoURL),
           let version = info["CFBundleShortVersionString"] as? String {
            let numeric = version.split(separator: " ").first.map(String.init) ?? version
            if !numeric.isEmpty { return numeric }
        }
        return "18.6"
    }
}

@MainActor
enum WebContentEnginePolicy {
    static func usesPersistentWebKit(
        for url: URL,
        profileId: String,
        allowsCredentialStorage: Bool,
        forceSystemMediaEngine: Bool = false
    ) -> Bool {
        _ = profileId
        _ = allowsCredentialStorage
        return forceSystemMediaEngine
            || SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(for: url)
    }
}

enum WebKitWebRTCPrivacyPolicy {
    /// WebKit does not expose Chromium's IP handling policy. Compatibility
    /// pages therefore disable peer connections before page scripts run so a
    /// fallback engine cannot bypass the process-wide CEF privacy boundary.
    static let javaScript = """
    (() => {
      const blockedPeerConnection = function RTCPeerConnection() {
        throw new DOMException(
          'WebRTC is unavailable in this compatibility view.',
          'NotAllowedError'
        );
      };
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
        try {
          Object.defineProperty(window, name, {
            value: blockedPeerConnection,
            writable: false,
            configurable: false
          });
        } catch (_) {
          window[name] = blockedPeerConnection;
        }
      }
    })();
    """
}

enum SystemMediaCompatibilityPolicy {
    private static let supportedDomains = [
        "acfun.cn",
        "aiyifan.club",
        "aiyifan.com.cn",
        "aiyifan.tv",
        "bbc.com",
        "bbc.co.uk",
        "bbci.co.uk",
        "bilibili.com",
        "douyin.com",
        "iq.com",
        "iqiyi.com",
        "ixigua.com",
        "iyf.tv",
        "mgtv.com",
        "miguvideo.com",
        "pptv.com",
        "tv.cctv.com",
        "tv.sohu.com",
        "twitter.com",
        "v.qq.com",
        "weibo.com",
        "x.com",
        "yahoo.com",
        "yangshipin.cn",
        "yfsp.tv",
        "youku.com",
    ]

    private static var detectedDomains = Set<String>()

    private static let chromiumOnlyDomains = [
        "grok.com",
    ]

    private static func matches(_ host: String, domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func allowsAutomaticFallback(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return !matches(host, domains: chromiumOnlyDomains)
    }

    static func requiresSystemMediaEngine(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        guard !matches(host, domains: chromiumOnlyDomains) else { return false }
        return detectedDomains.contains(host)
            || matches(host, domains: supportedDomains)
    }

    static func rememberDetectedMediaIncompatibility(for url: URL) {
        guard allowsAutomaticFallback(for: url),
              let host = url.host?.lowercased() else { return }
        detectedDomains.insert(host)
    }

    static func dataStoreIdentifier(forProfileId profileId: String) -> UUID {
        let digest = SHA256.hash(data: Data("Astra.SystemMedia.\(profileId)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum VisiblePageCaptureRoute: Equatable {
    case systemMedia
    case chromium

    static func active(hasSystemMediaPage: Bool) -> Self {
        hasSystemMediaPage ? .systemMedia : .chromium
    }
}

@MainActor
final class CefWebContentWrapper: NSObject, @preconcurrency WebContentWrapper, CefBrowserDelegate, PageContentProviding, BrowserAutomationProviding, MediaSessionCookieProviding, WKNavigationDelegate, WKUIDelegate {
    private final class PendingConsoleEvaluation {
        let continuation: CheckedContinuation<String?, Never>
        var chunks: [Int: String] = [:]
        var expectedChunkCount: Int?
        var timeoutWork: DispatchWorkItem?

        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }
    }

    private final class SystemMediaPopupHost: NSObject, WKUIDelegate, NSWindowDelegate {
        let webView: WKWebView
        let window: NSWindow
        var onClose: (() -> Void)?

        init(configuration: WKWebViewConfiguration) {
            webView = WKWebView(frame: .zero, configuration: configuration)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            super.init()
            webView.customUserAgent = SupportedBrowserUserAgent.safariCompatibleUserAgent
            webView.uiDelegate = self
            window.delegate = self
            window.contentView = webView
            window.isReleasedWhenClosed = false
        }

        func show(relativeTo parent: NSWindow?) {
            window.center()
            if let parent {
                parent.addChildWindow(window, ordered: .above)
            }
            window.makeKeyAndOrderFront(nil)
        }

        func webViewDidClose(_ webView: WKWebView) {
            window.close()
        }

        func windowWillClose(_ notification: Notification) {
            window.parent?.removeChildWindow(window)
            webView.uiDelegate = nil
            onClose?()
        }
    }

    private static let consoleResultPrefix = "__ASTRA_NATIVE_RESULT__"
    private static let mediaFallbackPrefix = "__ASTRA_SYSTEM_MEDIA_FALLBACK__"
    private final class HostView: NSView {
        weak var owner: CefWebContentWrapper?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.hostWindowDidChange()
        }

        override func layout() {
            super.layout()
            owner?.updateChromeOverlay()
        }

        override func viewDidHide() {
            super.viewDidHide()
            owner?.updateChromeOverlay()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            owner?.updateChromeOverlay()
        }
    }

    private(set) var browser: CefBrowser?
    private var chromeBrowser: CefChromeBrowser?
    private var systemMediaWebView: WKWebView?
    private let hostView = HostView(frame: .zero)
    private var pendingURL: URL
    private let retainedProfile: CefProfile
    private let profileId: String
    private let allowsCredentialStorage: Bool
    private weak var downloadsManager: DownloadsManager?
    private let pageContextToken = UUID().uuidString
    private var customGuid = ""
    private var didRequestClose = false
    private var didStartSmokeCheck = false
    private var didSchedulePageContextSmoke = false
    private weak var observedWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var nativePopupObservers: [NSObjectProtocol] = []
    private var nativePopupTimeout: DispatchWorkItem?
    private var pendingConsoleEvaluations: [String: PendingConsoleEvaluation] = [:]
    private var systemMediaPopupHosts: [ObjectIdentifier: SystemMediaPopupHost] = [:]

    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onMove: ((Int, Bool) -> Void)?
    var onOpenURLInNewTab: ((URL, Bool) -> Void)?

    @objc dynamic var nativeView: NSView? { hostView }
    @objc dynamic private(set) var isLoading = false
    @objc dynamic private(set) var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic private(set) var isFocused = false
    @objc dynamic private(set) var loadProgress: CGFloat = 0
    @objc dynamic private(set) var favIconURL: String?
    @objc dynamic private(set) var favIconData: Data?
    @objc dynamic private(set) var favIconRevision = 0
    @objc dynamic private(set) var canGoBack = false
    @objc dynamic private(set) var canGoForward = false
    @objc dynamic private(set) var title: String?
    @objc dynamic private(set) var urlString: String?
    @objc dynamic private(set) var securityInfo: [String: Any]?
    @objc dynamic private(set) var isCurrentlyAudible = false
    @objc dynamic private(set) var isAudioMuted = false
    @objc dynamic private(set) var isCapturingAudio = false
    @objc dynamic private(set) var isCapturingVideo = false
    @objc dynamic private(set) var isCapturingWindow = false
    @objc dynamic private(set) var isCapturingDisplay = false
    @objc dynamic private(set) var isCapturingTab = false
    @objc dynamic private(set) var isBeingMirrored = false
    @objc dynamic private(set) var isSharingScreen = false
    @objc dynamic private(set) var isInContentFullscreen = false
    @objc dynamic private(set) var isDistillable = false
    @objc dynamic var devToolsTargetId: String? { nil }

    init(
        urlString: String,
        profile: CefProfile,
        profileId: String,
        allowsCredentialStorage: Bool = true,
        downloadsManager: DownloadsManager? = nil
    ) {
        self.urlString = urlString
        self.pendingURL = Self.cefURL(for: urlString)
        self.retainedProfile = profile
        self.profileId = profileId
        self.allowsCredentialStorage = allowsCredentialStorage
        self.downloadsManager = downloadsManager
        super.init()
        hostView.owner = self
        hostView.autoresizesSubviews = true
    }

    func browser(
        _ browser: CefBrowser,
        decidePolicyForDownload download: CefDownload,
        suggestedName: String
    ) -> CefDownloadDecision {
        guard let downloadsManager else {
            return .allow(destination: nil)
        }
        let destination = downloadsManager.beginCEFDownload(download, suggestedName: suggestedName)
        return .allow(destination: destination)
    }

    func browser(_ browser: CefBrowser, downloadDidProgress download: CefDownload) {
        downloadsManager?.handleCEFDownloadProgress(download)
    }

    func browser(
        _ browser: CefBrowser,
        requestsPermission request: CefPermissionRequest
    ) -> CefPermissionDecision {
        let mediaKinds: CefPermissionKind = [.camera, .microphone]
        let requestedMedia = request.kinds.intersection(mediaKinds)
        guard !requestedMedia.isEmpty,
              request.kinds.subtracting(mediaKinds).isEmpty else {
            return .deny
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "privacy.mediaPermission.title",
            value: "Allow video call access?",
            comment: "Media permission prompt - Title shown when a website requests camera or microphone access"
        )
        let origin = URL(string: request.origin)?.host ?? request.origin
        alert.informativeText = String(
            format: NSLocalizedString(
                "privacy.mediaPermission.message",
                value: "%@ wants to use your camera or microphone. Allow this request once? Direct, non-proxied WebRTC connections remain blocked.",
                comment: "Media permission prompt - Explanation; placeholder is the website host requesting temporary camera or microphone access"
            ),
            origin
        )
        alert.addButton(withTitle: NSLocalizedString(
            "privacy.mediaPermission.allowOnceButton",
            value: "Allow This Time",
            comment: "Media permission prompt - Button granting camera or microphone access for the current request only"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "privacy.mediaPermission.denyButton",
            value: "Don't Allow",
            comment: "Media permission prompt - Button denying the current camera or microphone request"
        ))
        return alert.runModal() == .alertFirstButtonReturn ? .allow : .deny
    }

    private static func cefURL(for rawValue: String) -> URL {
        if rawValue.isEmpty || rawValue.isNTP {
            return URL(string: "about:blank")!
        }
        if URLProcessor.isLegacyBrowserMemoryURL(rawValue) {
            return URL(string: URLProcessor.browserMemoryURL)!
        }
        return URL(string: rawValue) ?? URL(string: URLProcessor.processUserInput(rawValue))
            ?? URL(string: "about:blank")!
    }

    fileprivate func createBrowserIfNeeded() {
        guard browser == nil, chromeBrowser == nil, systemMediaWebView == nil,
              hostView.window != nil else { return }
        if shouldUsePersistentWebKit(for: pendingURL) {
            // Chrome Runtime keeps only chrome:// pages. All http(s) content
            // uses a profile-scoped WebKit store so Google login, media sites,
            // and other profiles share one cookie jar inside Astra Browser.
            createSystemMediaWebView()
            return
        }

        var options = CefChromeBrowserOptions()
        options.isFrameless = true
        options.showsChromeToolbar = false
        options.initialBounds = chromeOverlayFrame()
        options.profile = retainedProfile
        let chromeBrowser = CefChromeBrowser.create(
            url: pendingURL,
            options: options,
            delegate: self
        )
        self.chromeBrowser = chromeBrowser
        browser = chromeBrowser.browser
        CefBrowserRuntime.shared.registerCredentialHandler(token: pageContextToken, handler: self)
        chromeBrowser.onWindowDestroyed = { [weak self] in
            guard let self else { return }
            CefBrowserRuntime.shared.unregisterCredentialHandler(token: self.pageContextToken)
            self.chromeBrowser = nil
            self.browser = nil
            self.onClose?()
        }
        if let overlay = chromeBrowser.nsWindow {
            overlay.isExcludedFromWindowsMenu = true
            overlay.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        updateChromeOverlay()
    }

    private func createSystemMediaWebView() {
        guard systemMediaWebView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = systemMediaDataStore()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // WKWebView disables the HTML Fullscreen API by default. Media sites
        // such as YouTube read document.fullscreenEnabled and otherwise report
        // that the browser does not support fullscreen.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.applicationNameForUserAgent = SupportedBrowserUserAgent.safariApplicationName
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebKitWebRTCPrivacyPolicy.javaScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: FingerprintPrivacyPolicy.javaScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: YouTubeAdPlaybackPolicy.javaScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: hostView.bounds, configuration: configuration)
        webView.customUserAgent = SupportedBrowserUserAgent.safariCompatibleUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        hostView.addSubview(webView)
        systemMediaWebView = webView
        webView.load(URLRequest(url: pendingURL))
        schedulePageContextSmokeIfNeeded()
    }

    private func systemMediaDataStore() -> WKWebsiteDataStore {
        guard allowsCredentialStorage else { return .nonPersistent() }
        let identifier = SystemMediaCompatibilityPolicy.dataStoreIdentifier(forProfileId: profileId)
        return WKWebsiteDataStore(forIdentifier: identifier)
    }

    private func removeSystemMediaWebView() {
        systemMediaWebView?.navigationDelegate = nil
        systemMediaWebView?.uiDelegate = nil
        systemMediaWebView?.stopLoading()
        systemMediaWebView?.removeFromSuperview()
        systemMediaWebView = nil
    }

    private func shouldUsePersistentWebKit(for url: URL) -> Bool {
        WebContentEnginePolicy.usesPersistentWebKit(
            for: url,
            profileId: profileId,
            allowsCredentialStorage: allowsCredentialStorage,
            forceSystemMediaEngine: CommandLine.arguments.contains("--astra-force-system-media-engine")
        )
    }

    fileprivate func hostWindowDidChange() {
        rebindWindowObservers()
        createBrowserIfNeeded()
        updateChromeOverlay()
    }

    fileprivate func updateChromeOverlay() {
        guard let overlay = chromeBrowser?.nsWindow else { return }
        let visible = systemMediaWebView == nil
            && hostView.window != nil
            && !hostView.isHiddenOrHasHiddenAncestor
            && (hostView.window?.isVisible ?? false)
            && !(hostView.window?.isMiniaturized ?? true)
            && hostView.bounds.width > 1
            && hostView.bounds.height > 1

        if visible, let parent = hostView.window {
            if overlay.parent !== parent {
                overlay.parent?.removeChildWindow(overlay)
                parent.addChildWindow(overlay, ordered: .above)
            }
            let frame = chromeOverlayFrame()
            if overlay.frame != frame {
                overlay.setFrame(frame, display: true)
            }
            overlay.orderFront(nil)
        } else {
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
    }

    /// Chrome-runtime identity pages require a real popup to preserve
    /// `window.opener`. CEF creates that popup as a top-level window, so attach
    /// it to the Astra window as soon as it is shown. This keeps authorization
    /// functional without exposing a standalone Chromium-shaped window.
    private func prepareToIntegrateNextNativePopup() {
        cancelNativePopupIntegration()
        guard let parentWindow = hostView.window else { return }

        let knownWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let centerName = NSWindow.didBecomeKeyNotification
        let observer = NotificationCenter.default.addObserver(
            forName: centerName,
            object: nil,
            queue: .main
        ) { [weak self, weak parentWindow] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let parentWindow,
                      let popupWindow = notification.object as? NSWindow,
                      !knownWindows.contains(ObjectIdentifier(popupWindow)),
                      popupWindow !== parentWindow,
                      popupWindow.parent == nil,
                      MainBrowserWindowControllersManager.shared
                        .findControllerWith(window: popupWindow) == nil else {
                    return
                }

                popupWindow.isExcludedFromWindowsMenu = true
                popupWindow.collectionBehavior.insert(.fullScreenAuxiliary)
                let parentFrame = parentWindow.frame
                let popupFrame = popupWindow.frame
                popupWindow.setFrameOrigin(NSPoint(
                    x: parentFrame.midX - popupFrame.width / 2,
                    y: parentFrame.midY - popupFrame.height / 2
                ))
                parentWindow.addChildWindow(popupWindow, ordered: .above)
                popupWindow.makeKeyAndOrderFront(nil)
                self.cancelNativePopupIntegration()
                AppLogInfo("[CEF] Attached native authorization popup to the Astra window")
            }
        }
        nativePopupObservers = [observer]

        let timeout = DispatchWorkItem { [weak self] in
            self?.cancelNativePopupIntegration()
        }
        nativePopupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func cancelNativePopupIntegration() {
        nativePopupTimeout?.cancel()
        nativePopupTimeout = nil
        nativePopupObservers.forEach(NotificationCenter.default.removeObserver)
        nativePopupObservers = []
    }

    private func chromeOverlayFrame() -> CGRect {
        guard let window = hostView.window else {
            return CGRect(x: 200, y: 200, width: max(hostView.bounds.width, 200), height: max(hostView.bounds.height, 150))
        }
        return window.convertToScreen(hostView.convert(hostView.bounds, to: nil))
    }

    private func rebindWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        observedWindow = hostView.window
        guard let window = observedWindow else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            windowObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateChromeOverlay()
                    }
                }
            )
        }
    }

    func close() {
        guard !didRequestClose else { return }
        didRequestClose = true
        cancelNativePopupIntegration()
        CefBrowserRuntime.shared.unregisterCredentialHandler(token: pageContextToken)
        let popupHosts = Array(systemMediaPopupHosts.values)
        systemMediaPopupHosts.removeAll()
        popupHosts.forEach { $0.window.close() }
        removeSystemMediaWebView()
        if let chromeBrowser {
            chromeBrowser.close()
        } else if let browser {
            browser.close(force: false)
        } else {
            onClose?()
        }
    }

    func reload() {
        if let systemMediaWebView {
            systemMediaWebView.reload()
        } else {
            browser?.reload()
        }
    }

    func reloadBypassingCache() {
        if let systemMediaWebView {
            systemMediaWebView.reloadFromOrigin()
        } else {
            browser?.reload(ignoreCache: true)
        }
    }

    func goBack() {
        if let systemMediaWebView {
            systemMediaWebView.goBack()
        } else {
            browser?.goBack()
        }
    }

    func goForward() {
        if let systemMediaWebView {
            systemMediaWebView.goForward()
        } else {
            browser?.goForward()
        }
    }

    func stopLoading() {
        if let systemMediaWebView {
            systemMediaWebView.stopLoading()
        } else {
            browser?.stopLoading()
        }
    }

    func navigate(toURL urlString: String) {
        self.urlString = urlString
        let destination = Self.cefURL(for: urlString)
        pendingURL = destination
        if shouldUsePersistentWebKit(for: destination) {
            if let systemMediaWebView {
                systemMediaWebView.load(URLRequest(url: destination))
            } else {
                chromeBrowser?.nsWindow?.orderOut(nil)
                createSystemMediaWebView()
            }
        } else if let browser {
            removeSystemMediaWebView()
            browser.load(destination)
            updateChromeOverlay()
        } else {
            removeSystemMediaWebView()
            createBrowserIfNeeded()
        }
    }

    private func switchCurrentPageToSystemMediaEngine(_ url: URL) {
        guard systemMediaWebView == nil,
              url.scheme?.lowercased() == "https" else { return }
        pendingURL = url
        urlString = url.absoluteString
        chromeBrowser?.nsWindow?.orderOut(nil)
        createSystemMediaWebView()
    }

    func setAsActiveTab() {
        onActivate?()
        focus()
    }

    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {
        onMove?(newIndex, selectAfterMove)
    }

    func moveSelf(toNewWindow activateNewWindow: Bool) {}

    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}

    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        beforeTabId anchorTabId: Int64
    ) {}

    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        afterTabId anchorTabId: Int64
    ) {}

    func moveSplit(toNewWindow activateNewWindow: Bool) {}

    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}

    func updateTabCustomValue(_ customValue: String) {
        customGuid = customValue
    }

    func focus() {
        if let systemMediaWebView {
            hostView.window?.makeFirstResponder(systemMediaWebView)
        } else {
            chromeBrowser?.nsWindow?.makeKey()
        }
        isFocused = true
    }

    func restoreFocus() {
        focus()
    }

    func updateSecurityState(_ securityState: [AnyHashable: Any]) {
        securityInfo = securityState.reduce(into: [:]) { result, item in
            guard let key = item.key as? String else { return }
            result[key] = item.value
        }
    }

    func setAudioMuted(_ muted: Bool) {
        if let systemMediaWebView {
            systemMediaWebView.evaluateJavaScript(
                "document.querySelectorAll('video,audio').forEach((media) => media.muted = \(muted ? "true" : "false"));"
            )
        } else {
            browser?.isAudioMuted = muted
        }
        isAudioMuted = muted
    }

    func muteAudio() {
        setAudioMuted(true)
    }

    func unmuteAudio() {
        setAudioMuted(false)
    }

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping @Sendable ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    func browser(_ browser: CefBrowser, didChangeTitle title: String) {
        self.title = title
        runSmokeCheckIfReady()
    }

    func browser(_ browser: CefBrowser, didChangeURL url: URL?) {
        guard let url, url.absoluteString != "about:blank" || urlString?.isNTP != true else { return }
        urlString = url.absoluteString
        securityInfo = [
            "securityLevel": url.scheme?.lowercased() == "https" ? 3 : 0,
            "hasCertificate": url.scheme?.lowercased() == "https",
        ]
        installWebResourceCompatibility()
        schedulePageContextSmokeIfNeeded()
    }

    func browser(
        _ browser: CefBrowser,
        didChangeLoading isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        self.isLoading = isLoading
        self.loadingState = PhiTabLoadingState(rawValue: isLoading ? 2 : 0)!
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if isLoading {
            installWebResourceCompatibility()
        } else {
            loadProgress = 1
            installYouTubeAdPlaybackControl()
            installWebCredentialControls()
            installWebResourceCompatibility()
            installAutomaticMediaCompatibilityDetection()
            runSmokeCheckIfReady()
        }
    }

    private func installYouTubeAdPlaybackControl() {
        guard let browser,
              let pageURL = URL(string: urlString ?? pendingURL.absoluteString),
              YouTubeAdPlaybackPolicy.supports(host: pageURL.host) else { return }
        browser.executeJavaScript(YouTubeAdPlaybackPolicy.javaScript)
    }

    private func installAutomaticMediaCompatibilityDetection() {
        guard let browser,
              let pageURL = URL(string: urlString ?? pendingURL.absoluteString),
              SystemMediaCompatibilityPolicy.allowsAutomaticFallback(for: pageURL) else { return }
        let prefix = Self.javaScriptLiteral(Self.mediaFallbackPrefix)
        let script = """
        (function () {
          if (window.__astraMediaCompatibilityDetectionInstalled) return;
          window.__astraMediaCompatibilityDetectionInstalled = true;
          const probe = document.createElement('video');
          const missingH264 = !probe.canPlayType('video/mp4; codecs="avc1.42E01E"');
          const missingAAC = !probe.canPlayType('audio/mp4; codecs="mp4a.40.2"');
          if (!missingH264 && !missingAAC) return;

          let reported = false;
          const firstSeen = new WeakMap();
          const isVisible = (element, minimumWidth = 120, minimumHeight = 70) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width >= minimumWidth && rect.height >= minimumHeight &&
              style.display !== 'none' && style.visibility !== 'hidden';
          };
          const hasVisibleHTML5Failure = () =>
            Array.from(document.querySelectorAll('body *')).some((element) => {
              if (!isVisible(element, 300, 150) || element.querySelector('video, audio')) return false;
              const text = (element.innerText || '').replace(/\\s+/g, ' ').trim().toLowerCase();
              return text.length > 0 && text.length <= 300 && text.includes('html5');
            });
          const declaresUnsupportedFormat = (media) => {
            const sources = [media, ...media.querySelectorAll('source')];
            return sources.some((source) => {
              const type = (source.type || '').toLowerCase();
              const url = (source.currentSrc || source.src || '').toLowerCase().split('?')[0];
              return (missingH264 && (type.includes('video/mp4') || type.includes('avc1') ||
                url.endsWith('.mp4') || url.endsWith('.m4v') || url.endsWith('.m3u8'))) ||
                (missingAAC && (type.includes('audio/mp4') || type.includes('mp4a') ||
                type.includes('aac') || url.endsWith('.m4a') || url.endsWith('.aac')));
            });
          };
          const report = () => {
            if (reported) return;
            reported = true;
            console.warn(\(prefix) + location.href);
          };
          const inspect = () => {
            if (hasVisibleHTML5Failure()) {
              report();
              return;
            }
            const now = performance.now();
            for (const media of document.querySelectorAll('video, audio')) {
              if (!isVisible(media)) continue;
              if (!firstSeen.has(media)) firstSeen.set(media, now);
              const unsupportedError = media.error && (media.error.code === 3 || media.error.code === 4);
              const stalledUnsupportedMedia = declaresUnsupportedFormat(media) &&
                media.readyState <= HTMLMediaElement.HAVE_METADATA &&
                now - firstSeen.get(media) >= 6000;
              const hasMediaRequest = Boolean(
                media.currentSrc || media.src || media.querySelector('source[src]') ||
                media.autoplay || !media.paused
              );
              const stalledUnknownMedia = hasMediaRequest &&
                media.readyState === HTMLMediaElement.HAVE_NOTHING &&
                now - firstSeen.get(media) >= 10000;
              if (unsupportedError || stalledUnsupportedMedia || stalledUnknownMedia) {
                report();
                return;
              }
            }
          };
          document.addEventListener('error', inspect, true);
          document.addEventListener('stalled', inspect, true);
          document.addEventListener('waiting', inspect, true);
          new MutationObserver(inspect).observe(document.documentElement, {
            childList: true, subtree: true, attributes: true,
            attributeFilter: ['src', 'type']
          });
          setInterval(inspect, 2000);
          inspect();
        })();
        """
        browser.executeJavaScript(script)
    }

    private func installWebResourceCompatibility() {
        guard let browser,
              let pageURL = URL(string: urlString ?? pendingURL.absoluteString),
              WebResourceCompatibilityPolicy.permitsPageMutation(for: pageURL) else { return }

        let script = """
        (function () {
          const install = () => {
          if (window.__astraWebResourceCompatibilityInstalled || !document.documentElement) return;
          window.__astraWebResourceCompatibilityInstalled = true;
          const isNetEaseResource = (hostname) =>
            hostname === '163.com' || hostname.endsWith('.163.com') ||
            hostname === '126.com' || hostname.endsWith('.126.com') ||
            hostname === '126.net' || hostname.endsWith('.126.net');
          const upgrade = (value) => {
            if (!value || typeof value !== 'string') return value;
            const trimmed = value.trim();
            if (!trimmed || trimmed.startsWith('data:') || trimmed.startsWith('blob:') ||
                trimmed.startsWith('javascript:') || trimmed.startsWith('#')) return value;
            try {
              const url = new URL(trimmed, location.href);
              if (location.protocol === 'https:' && url.protocol === 'http:') {
                url.protocol = 'https:';
              }
              return url.href;
            } catch (_) {}
            return value;
          };
          const upgradeSrcset = (value) => value ? value.split(',').map((candidate) => {
            const parts = candidate.trim().split(/\\s+/);
            parts[0] = upgrade(parts[0]);
            return parts.join(' ');
          }).join(', ') : value;
          const candidateAttributes = [
            'data-src', 'data-original', 'data-lazy-src', 'data-original-src',
            'data-image', 'data-url', 'data-actualsrc', 'data-actual-src',
            'data-echo', 'data-lazy', 'data-bg', 'data-bg-src', 'data-background',
            'data-background-image', '_src', 'src2'
          ];
          const firstCandidate = (element) => {
            for (const attribute of candidateAttributes) {
              const candidate = upgrade(element.getAttribute?.(attribute));
              if (candidate && (candidate.startsWith('https://') || candidate.startsWith('http://'))) return candidate;
            }
            return '';
          };
          const useProxySourceFallback = (image, force) => {
            if (!(image instanceof HTMLImageElement) || image.dataset.astraProxyFallback === '1') return;
            try {
              const proxyURL = new URL(image.currentSrc || image.src, location.href);
              if (proxyURL.hostname.toLowerCase() !== 'nimg.ws.126.net') return;
              const source = proxyURL.searchParams.get('url');
              const upgradedSource = upgrade(source);
              if (!upgradedSource ||
                  (!upgradedSource.startsWith('https://') && !upgradedSource.startsWith('http://'))) return;
              if (!force && image.naturalWidth > 1 && image.naturalHeight > 1) return;
              image.dataset.astraProxyFallback = '1';
              image.removeAttribute('srcset');
              image.src = upgradedSource;
            } catch (_) {}
          };
          const promoteLazyImageSource = (image) => {
            if (!(image instanceof HTMLImageElement)) return;
            const currentSource = image.currentSrc || image.src || '';
            const isTransparentPlaceholder = currentSource.startsWith('data:image/') &&
              (!image.complete || image.naturalWidth <= 1 || image.naturalHeight <= 1);
            const hasFailed = image.complete && image.naturalWidth === 0;
            if (!isTransparentPlaceholder && !hasFailed && currentSource) return;
            const candidate = firstCandidate(image);
            if (!candidate || candidate === currentSource) return;
            image.removeAttribute('srcset');
            image.src = candidate;
          };
          const promoteResponsiveSource = (element) => {
            if (!(element instanceof HTMLImageElement || element instanceof HTMLSourceElement)) return;
            const candidate = element.getAttribute('data-srcset') || element.getAttribute('data-lazy-srcset');
            if (candidate && !element.getAttribute('srcset')) {
              element.setAttribute('srcset', upgradeSrcset(candidate));
            }
          };
          const promoteBackgroundSource = (element) => {
            if (!(element instanceof HTMLElement) || element instanceof HTMLImageElement) return;
            const candidate = firstCandidate(element);
            if (!candidate) return;
            const background = getComputedStyle(element).backgroundImage || '';
            if (background && background !== 'none' && !background.includes('data:image/')) return;
            element.style.backgroundImage = `url("${candidate.replaceAll('"', '%22')}")`;
          };
          const promoteMediaPoster = (element) => {
            if (!(element instanceof HTMLVideoElement)) return;
            const candidate = upgrade(element.getAttribute('data-poster'));
            if (candidate && !element.poster) element.poster = candidate;
          };
          const repair = (root) => {
            const elements = [];
            if (root && root.nodeType === Node.ELEMENT_NODE) elements.push(root);
            if (root && root.querySelectorAll) {
              elements.push(...root.querySelectorAll(
                'img, source, video, a[download], [data-src], [data-original], [data-lazy-src], ' +
                '[data-image], [data-actualsrc], [data-bg], [data-bg-src], [data-background], ' +
                '[data-background-image], [_src], [src2]'
              ));
            }
            for (const element of elements) {
              const safeAttributes = [];
              if (element instanceof HTMLImageElement || element instanceof HTMLSourceElement ||
                  element instanceof HTMLVideoElement || element instanceof HTMLAudioElement) {
                safeAttributes.push('src');
              }
              if (element instanceof HTMLAnchorElement && element.hasAttribute('download')) {
                safeAttributes.push('href');
              }
              if (element instanceof HTMLVideoElement) safeAttributes.push('poster');
              for (const attribute of safeAttributes) {
                if (!element.hasAttribute(attribute)) continue;
                const original = element.getAttribute(attribute);
                const upgraded = upgrade(original);
                if (upgraded !== original) element.setAttribute(attribute, upgraded);
              }
              if (element.hasAttribute('srcset')) {
                const original = element.getAttribute('srcset');
                const upgraded = upgradeSrcset(original);
                if (upgraded !== original) element.setAttribute('srcset', upgraded);
              }
              promoteResponsiveSource(element);
              promoteLazyImageSource(element);
              promoteBackgroundSource(element);
              promoteMediaPoster(element);
              if (element instanceof HTMLImageElement && element.complete && element.naturalWidth === 0) {
                useProxySourceFallback(element, true);
              }
            }
          };
          document.addEventListener('error', (event) => {
            if (event.target instanceof HTMLImageElement) {
              promoteLazyImageSource(event.target);
              useProxySourceFallback(event.target, true);
            }
          }, true);
          repair(document);
          new MutationObserver((records) => {
            for (const record of records) {
              if (record.type === 'attributes') repair(record.target);
              for (const node of record.addedNodes || []) repair(node);
            }
          }).observe(document.documentElement, {
            subtree: true,
            childList: true,
            attributes: true,
            attributeFilter: [
              'src', 'srcset', 'data-src', 'data-original', 'data-lazy-src',
              'data-original-src', 'data-image', 'data-url', 'href', 'poster',
              'data-actualsrc', 'data-actual-src', 'data-echo', 'data-lazy',
              'data-srcset', 'data-lazy-srcset', 'data-bg', 'data-bg-src',
              'data-background', 'data-background-image', '_src', 'src2'
            ]
          });
          let scrollRepairScheduled = false;
          document.addEventListener('scroll', () => {
            if (scrollRepairScheduled) return;
            scrollRepairScheduled = true;
            requestAnimationFrame(() => {
              scrollRepairScheduled = false;
              repair(document);
            });
          }, true);
          [250, 800, 2000, 5000, 10000].forEach((delay) => setTimeout(() => repair(document), delay));
          };
          if (document.documentElement) install();
          else document.addEventListener('DOMContentLoaded', install, { once: true });
        })();
        """
        browser.executeJavaScript(script)
    }

    private func installWebCredentialControls() {
        guard allowsCredentialStorage,
              let browser,
              let origin = currentSecureOrigin() else { return }
        let fillTitle = NSLocalizedString(
            "passwords.webCredential.fillButton.title",
            value: "Fill with Touch ID",
            comment: "Web password manager - Button injected on HTTPS login pages to fill a saved password"
        )
        let tokenLiteral = Self.javaScriptLiteral(pageContextToken)
        let originLiteral = Self.javaScriptLiteral(origin)
        let titleLiteral = Self.javaScriptLiteral(fillTitle)
        let script = """
        (function () {
          if (window.__astraCredentialControlsInstalled) return;
          window.__astraCredentialControlsInstalled = true;
          const bridgeToken = \(tokenLiteral);
          const expectedOrigin = \(originLiteral);
          if (location.origin !== expectedOrigin || !window.cefSwift || !window.cefSwift.invoke) return;

          const isVisible = (element) => {
            if (!element || element.disabled) return false;
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          };
          const username = () => {
            const selectors = [
              'input[autocomplete="username"]', 'input[type="email"]',
              'input[name="identifier"]', 'input[name="Email"]', 'input[name="email"]'
            ];
            for (const selector of selectors) {
              const value = document.querySelector(selector)?.value?.trim();
              if (value) return value.slice(0, 320);
            }
            for (const selector of ['[data-email]', '[data-identifier]']) {
              const element = document.querySelector(selector);
              const value = element?.getAttribute('data-email') || element?.getAttribute('data-identifier');
              if (value) return value.trim().slice(0, 320);
            }
            return '';
          };
          const passwordField = () => Array.from(document.querySelectorAll('input[type="password"]')).find(isVisible);
          const addFillButton = () => {
            const password = passwordField();
            let button = document.getElementById('astra-touch-id-fill');
            if (!password) {
              if (button) button.remove();
              return;
            }
            if (button) return;
            button = document.createElement('button');
            button.id = 'astra-touch-id-fill';
            button.type = 'button';
            button.textContent = \(titleLiteral);
            button.setAttribute('aria-label', \(titleLiteral));
            Object.assign(button.style, {
              position: 'fixed', right: '18px', bottom: '18px', zIndex: '2147483647',
              border: '0', borderRadius: '9px', padding: '10px 14px', cursor: 'pointer',
              color: 'white', background: '#1473e6', font: '600 13px -apple-system, BlinkMacSystemFont, sans-serif',
              boxShadow: '0 4px 18px rgba(0,0,0,.24)'
            });
            button.addEventListener('click', () => {
              void window.cefSwift.invoke('astraWebCredential', {
                action: 'fill', token: bridgeToken, origin: location.origin, username: username(), password: null
              });
            });
            document.documentElement.appendChild(button);
          };
          document.addEventListener('submit', (event) => {
            const form = event.target;
            const password = form?.querySelector?.('input[type="password"]') || passwordField();
            if (!password?.value || password.dataset.astraCredentialSent === 'true') return;
            password.dataset.astraCredentialSent = 'true';
            void window.cefSwift.invoke('astraWebCredential', {
              action: 'save', token: bridgeToken, origin: location.origin,
              username: username(), password: password.value.slice(0, 4096)
            });
          }, true);
          addFillButton();
          new MutationObserver(addFillButton).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        browser.executeJavaScript(script)
    }

    func handleWebCredentialRequest(
        action: String,
        origin: String,
        username: String?,
        password: String?
    ) {
        guard allowsCredentialStorage,
              let secureOrigin = WebCredentialStore.secureOrigin(from: origin),
              secureOrigin == currentSecureOrigin() else { return }
        switch action {
        case "fill":
            fillSavedCredential(origin: secureOrigin, requestedUsername: username)
        case "save":
            saveSubmittedCredential(
                origin: secureOrigin,
                username: username ?? "",
                password: password ?? ""
            )
        default:
            return
        }
    }

    private func fillSavedCredential(origin: String, requestedUsername: String?) {
        let descriptors = WebCredentialStore.shared.descriptors(for: origin)
        let trimmedUsername = requestedUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matching = trimmedUsername.isEmpty
            ? descriptors
            : descriptors.filter { $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame }
        let candidates = matching.isEmpty ? descriptors : matching
        guard let descriptor = WebCredentialPrompt.choose(
            from: candidates,
            origin: origin,
            window: hostView.window
        ) else { return }
        let reason = String(
            format: NSLocalizedString(
                "passwords.webCredential.touchID.fillReason",
                value: "Fill the saved login for %@ on %@",
                comment: "Web password manager - Touch ID reason; placeholders are the username and website origin"
            ),
            descriptor.username,
            origin
        )
        do {
            let password = try WebCredentialStore.shared.password(for: descriptor, reason: reason)
            fillCredential(username: descriptor.username, password: password, origin: origin)
        } catch WebCredentialStoreError.keychain(let status)
            where status == errSecUserCanceled || status == errSecAuthFailed {
            return
        } catch {
            WebCredentialPrompt.showError(error, window: hostView.window)
        }
    }

    private func saveSubmittedCredential(origin: String, username: String, password: String) {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { return }
        guard WebCredentialPrompt.confirmSave(
            username: trimmedUsername,
            origin: origin,
            window: hostView.window
        ) else { return }
        do {
            try WebCredentialStore.shared.save(
                origin: origin,
                username: trimmedUsername,
                password: password
            )
        } catch WebCredentialStoreError.keychain(let status)
            where status == errSecUserCanceled || status == errSecAuthFailed {
            return
        } catch {
            WebCredentialPrompt.showError(error, window: hostView.window)
        }
    }

    private func fillCredential(username: String, password: String, origin: String) {
        guard let browser else { return }
        let usernameLiteral = Self.javaScriptLiteral(username)
        let passwordLiteral = Self.javaScriptLiteral(password)
        let originLiteral = Self.javaScriptLiteral(origin)
        let script = """
        (function () {
          if (location.origin !== \(originLiteral)) return;
          const update = (element, value) => {
            if (!element) return;
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
            setter ? setter.call(element, value) : (element.value = value);
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const password = Array.from(document.querySelectorAll('input[type="password"]')).find((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && !element.disabled;
          });
          const username = document.querySelector(
            'input[autocomplete="username"], input[type="email"], input[name="identifier"], input[name="Email"], input[name="email"]'
          );
          if (username && !username.value) update(username, \(usernameLiteral));
          update(password, \(passwordLiteral));
          password?.focus();
        })();
        """
        browser.executeJavaScript(script)
    }

    private func currentSecureOrigin() -> String? {
        WebCredentialStore.secureOrigin(from: urlString ?? pendingURL.absoluteString)
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    private func runSmokeCheckIfReady() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--cef-smoke-test"), !didStartSmokeCheck else { return }

        if arguments.contains("--cef-external-open-smoke") {
            guard !isLoading,
                  let urlString,
                  urlString.contains("astra-external-open-smoke=1") else {
                return
            }
            didStartSmokeCheck = true
            FileHandle.standardOutput.write(
                Data("[cef-smoke] external open: \(urlString)\n".utf8)
            )
            NSApp.terminate(nil)
            return
        }

        if arguments.contains("--cef-memory-api-smoke") {
            guard !isLoading, browser != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let operation = """
                try {
                  const response = await fetch('/api/memories');
                  const payload = await response.json();
                  return JSON.stringify({
                    ok: response.ok,
                    status: response.status,
                    isArray: Array.isArray(payload)
                  });
                } catch (error) {
                  return JSON.stringify({
                    ok: false,
                    message: String(error && error.message ? error.message : error)
                  });
                }
                """
                let result = await evaluateJavaScriptResult(
                    operation: operation,
                    timeout: 8
                ) ?? "unavailable"
                let succeeded = result.contains("\"ok\":true")
                    && result.contains("\"status\":200")
                    && result.contains("\"isArray\":true")
                let status = succeeded ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] memory API \(status): \(result)\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-visual-automation-smoke") {
            guard !isLoading, browser != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self,
                      let point = BrowserAutomationPoint(x: 500, y: 500) else { return }
                let resultTarget = BrowserAutomationTarget(
                    index: nil,
                    ref: nil,
                    selector: "#astra-visual-result",
                    matchIndex: nil
                )
                let inspection = await captureVisualAutomationPage()
                let clicked = await clickVisualAutomationPoint(point)
                let waited = await waitForAutomationElement(resultTarget, milliseconds: 2_000)
                let succeeded = inspection.succeeded
                    && inspection.imageDataURL?.hasPrefix("data:image/jpeg;base64,") == true
                    && clicked.succeeded
                    && waited.succeeded
                let status = succeeded ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] visual automation \(status)\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-inspection-stress-smoke") {
            guard !isLoading, browser != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let start = ProcessInfo.processInfo.systemUptime
                let inspection = await inspectPageForAutomation()
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let succeeded = inspection.succeeded
                    && inspection.message.contains("Complex news page")
                    && elapsed < 5.5
                let status = succeeded ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] inspection stress \(status) in \(String(format: "%.2f", elapsed))s\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-automation-smoke") {
            guard !isLoading, browser != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let inputTarget = BrowserAutomationTarget(
                    index: nil,
                    ref: nil,
                    selector: "#astra-smoke-input",
                    matchIndex: nil
                )
                let buttonTarget = BrowserAutomationTarget(
                    index: nil,
                    ref: nil,
                    selector: "#astra-smoke-reveal",
                    matchIndex: nil
                )
                let resultTarget = BrowserAutomationTarget(
                    index: nil,
                    ref: nil,
                    selector: "#astra-smoke-result",
                    matchIndex: nil
                )
                let inspection = await inspectPageForAutomation()
                let typed = await typeAutomationText("Astra DOM", into: inputTarget)
                let clicked = await clickAutomationTarget(buttonTarget)
                let waited = await waitForAutomationElement(resultTarget, milliseconds: 2_000)
                let finalInspection = await inspectPageForAutomation()
                let succeeded = inspection.succeeded
                    && inspection.message.contains("\"html\":")
                    && inspection.message.contains("\"ref\":")
                    && inspection.message.contains("\"selector\":")
                    && typed.succeeded
                    && clicked.succeeded
                    && waited.succeeded
                    && finalInspection.message.contains("Automation complete")
                let status = succeeded ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] DOM automation \(status)\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-popup-opener-smoke") {
            guard !isLoading, browser != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let target = BrowserAutomationTarget(
                    index: nil,
                    ref: nil,
                    selector: "#open-popup",
                    matchIndex: nil
                )
                let clicked = await clickAutomationTarget(target)
                try? await Task.sleep(for: .seconds(3))
                let content = await pageContentContext() ?? ""
                let succeeded = clicked.succeeded && content.contains("OPENER_PRESERVED")
                let status = succeeded ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] popup opener \(status): \(content.prefix(120))\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-page-context-smoke") {
            guard !isLoading, browser != nil else { return }
            startPageContextSmoke()
            return
        }

        if arguments.contains("--cef-webrtc-privacy-smoke") {
            guard !isLoading, browser != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let operation = """
                const connection = new RTCPeerConnection({
                  iceServers: [
                    { urls: 'stun:stun.l.google.com:19302' },
                    { urls: 'stun:stun.cloudflare.com:3478' }
                  ]
                });
                const candidates = [];
                connection.createDataChannel('privacy-probe');
                const gatheringComplete = new Promise((resolve) => {
                  const timeout = setTimeout(resolve, 8000);
                  connection.addEventListener('icecandidate', (event) => {
                    if (event.candidate) {
                      candidates.push({
                        address: event.candidate.address || '',
                        protocol: event.candidate.protocol || '',
                        type: event.candidate.type || '',
                        candidate: event.candidate.candidate
                      });
                    } else {
                      clearTimeout(timeout);
                      resolve();
                    }
                  });
                });
                await connection.setLocalDescription(await connection.createOffer());
                await gatheringComplete;
                connection.close();
                return JSON.stringify({
                  ok: candidates.length === 0,
                  candidates
                });
                """
                let result = await evaluateJavaScriptResult(operation: operation, timeout: 12) ?? "unavailable"
                let status = result.contains("\"ok\":true") ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] WebRTC privacy \(status): \(result)\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-image-compatibility-smoke") {
            guard !isLoading, browser != nil || systemMediaWebView != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(5))
                let operation = """
                const visibleImages = Array.from(document.images).filter((image) => {
                  const rect = image.getBoundingClientRect();
                  return rect.width > 40 && rect.height > 40;
                });
                const brokenImages = visibleImages.filter((image) => image.complete && image.naturalWidth === 0);
                const placeholderImages = visibleImages.filter((image) => {
                  const source = (image.currentSrc || image.src || '').toLowerCase();
                  const lazySource = image.getAttribute('data-src') || image.getAttribute('data-original') || '';
                  let resolvedLazySource = '';
                  try { resolvedLazySource = new URL(lazySource, location.href).href.toLowerCase(); } catch (_) {}
                  return source.includes('default') || source.includes('placeholder') ||
                    source.includes('loading') || source.includes('imgdf.') ||
                    (resolvedLazySource && source !== resolvedLazySource);
                });
                const describe = (image) => ({
                  source: image.currentSrc || image.src,
                  dimensions: {
                    renderedWidth: Math.round(image.getBoundingClientRect().width),
                    renderedHeight: Math.round(image.getBoundingClientRect().height),
                    naturalWidth: image.naturalWidth,
                    naturalHeight: image.naturalHeight
                  },
                  attributes: Array.from(image.attributes).reduce((result, attribute) => {
                    result[attribute.name] = attribute.value;
                    return result;
                  }, {}),
                  parent: image.parentElement ? image.parentElement.outerHTML.slice(0, 1800) : ''
                });
                const largeImages = visibleImages.filter((image) => {
                  const rect = image.getBoundingClientRect();
                  return rect.width > 250 && rect.height > 140;
                });
                return JSON.stringify({
                  visible: visibleImages.length,
                  broken: brokenImages.length,
                  brokenImages: brokenImages.slice(0, 8).map(describe),
                  placeholders: placeholderImages.slice(0, 12).map(describe),
                  largeImages: largeImages.slice(0, 30).map(describe)
                });
                """
                let result = await evaluateJavaScriptResult(operation: operation, timeout: 8) ?? "unavailable"
                FileHandle.standardOutput.write(Data("[cef-smoke] image compatibility: \(result)\n".utf8))
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-media-compatibility-smoke") {
            guard !isLoading, browser != nil || systemMediaWebView != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(5))
                let operation = """
                const probe = document.createElement('video');
                const support = (type) => ({
                  element: probe.canPlayType(type),
                  mediaSource: typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported
                    ? MediaSource.isTypeSupported(type)
                    : false
                });
                const videos = Array.from(document.querySelectorAll('video')).map((video) => ({
                  currentSrc: video.currentSrc,
                  source: video.src,
                  readyState: video.readyState,
                  networkState: video.networkState,
                  paused: video.paused,
                  error: video.error ? { code: video.error.code, message: video.error.message } : null,
                  sources: Array.from(video.querySelectorAll('source')).map((source) => ({
                    src: source.src,
                    type: source.type
                  }))
                }));
                return JSON.stringify({
                  codecs: {
                    h264: support('video/mp4; codecs="avc1.42E01E"'),
                    aac: support('audio/mp4; codecs="mp4a.40.2"'),
                    vp9: support('video/webm; codecs="vp9"'),
                    av1: support('video/mp4; codecs="av01.0.05M.08"')
                  },
                  encryptedMedia: typeof navigator.requestMediaKeySystemAccess === 'function',
                  videos
                });
                """
                let result = await evaluateJavaScriptResult(operation: operation, timeout: 8) ?? "unavailable"
                FileHandle.standardOutput.write(Data("[cef-smoke] media compatibility: \(result)\n".utf8))
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-audio-privacy-smoke") {
            guard !isLoading, browser != nil || systemMediaWebView != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let operation = """
                const AudioContextConstructor = globalThis.AudioContext || globalThis.webkitAudioContext;
                if (globalThis.__astraAudioPrivacyInstalled !== true) return 'unprotected';
                if (typeof AudioContextConstructor !== 'function') return 'protected';
                try {
                  const context = new AudioContextConstructor();
                  context.close?.();
                  return 'protected';
                } catch (_) {
                  return 'protected';
                }
                """
                let result = await evaluateJavaScriptResult(operation: operation, timeout: 8) ?? "unavailable"
                FileHandle.standardOutput.write(Data("[cef-smoke] web audio: \(result)\n".utf8))
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-fingerprint-site-smoke") {
            guard !isLoading, browser != nil || systemMediaWebView != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let operation = """
                await new Promise((resolve) => setTimeout(resolve, 2_000));
                const localizedStartLabel = String.fromCharCode(
                  0x5f00, 0x59cb, 0x68c0, 0x6d4b
                );
                const localizedDismissLabel = String.fromCharCode(
                  0x6211, 0x77e5, 0x9053, 0x4e86
                );
                const initialControls = Array.from(document.querySelectorAll('button, a'));
                const dismissControl = initialControls.find((element) => {
                  const label = (element.innerText || element.textContent || '').trim();
                  return label.includes(localizedDismissLabel)
                    || label.toLowerCase().includes('got it');
                });
                if (dismissControl) {
                  dismissControl.click();
                  await new Promise((resolve) => setTimeout(resolve, 1_000));
                }
                const startControl = Array.from(document.querySelectorAll('button, a')).find((element) => {
                  const label = (element.innerText || element.textContent || '').trim();
                  const normalizedLabel = label.toLowerCase();
                  return label.includes(localizedStartLabel)
                    || normalizedLabel.includes('start test')
                    || normalizedLabel.includes('start check');
                });
                if (!startControl) {
                  return JSON.stringify({
                    ok: false,
                    message: 'start control not found',
                    controls: Array.from(document.querySelectorAll('button, a'))
                      .map((element) => (element.innerText || element.textContent || '').trim())
                      .filter(Boolean)
                      .slice(0, 40)
                  });
                }
                startControl.click();
                await new Promise((resolve) => setTimeout(resolve, 8_000));
                return document.body?.innerText || '';
                """
                let result = await evaluateJavaScriptResult(operation: operation, timeout: 12)
                    ?? "unavailable"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] fingerprint site: \(result)\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--cef-fingerprint-privacy-smoke") {
            guard !isLoading, browser != nil || systemMediaWebView != nil else { return }
            didStartSmokeCheck = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let operation = """
                return (() => {
                  const canvas = document.createElement('canvas');
                  canvas.width = 32;
                  canvas.height = 16;
                  const context = canvas.getContext('2d');
                  context.font = '16px "PingFang SC", monospace';
                  context.fillText('Astra privacy', 1, 12);
                  const webglCanvas = document.createElement('canvas');
                  const webgl = webglCanvas.getContext('webgl2') || webglCanvas.getContext('webgl');
                  const rendererExtension = webgl?.getExtension('WEBGL_debug_renderer_info');
                  const renderer = rendererExtension
                    ? webgl.getParameter(rendererExtension.UNMASKED_RENDERER_WEBGL)
                    : null;
                  const protectedFontNames = [
                    'PingFang SC', 'Hiragino Sans GB', 'STHeiti', 'STSong',
                    'Microsoft YaHei', 'SimSun', 'SimHei', 'Noto Sans CJK SC'
                  ];
                  const genericFamilies = ['monospace', 'sans-serif', 'serif'];
                  const fontProbe = document.createElement('span');
                  fontProbe.style.position = 'absolute';
                  fontProbe.style.left = '-9999px';
                  fontProbe.style.fontSize = '72px';
                  fontProbe.textContent = 'mmmmmmmmmmlli';
                  document.body.appendChild(fontProbe);
                  const genericWidths = Object.fromEntries(genericFamilies.map((family) => {
                    fontProbe.style.fontFamily = family;
                    return [family, fontProbe.offsetWidth];
                  }));
                  const protectedFontsDetected = protectedFontNames.filter((fontName) =>
                    genericFamilies.some((family) => {
                      fontProbe.style.fontFamily = `'${fontName}', ${family}`;
                      return fontProbe.offsetWidth !== genericWidths[family];
                    })
                  );
                  fontProbe.remove();
                  return JSON.stringify({
                    installed: globalThis.__astraFingerprintPrivacyInstalled === true,
                    audioInstalled: globalThis.__astraAudioPrivacyInstalled === true,
                    canvas: canvas.toDataURL().slice(0, 32),
                    renderer,
                    pingFangVisible: document.fonts.check('16px "PingFang SC"'),
                    hiraginoVisible: document.fonts.check('16px "Hiragino Sans GB"'),
                    protectedFontsDetected,
                    hardwareConcurrency: navigator.hardwareConcurrency,
                    deviceMemory: navigator.deviceMemory ?? null,
                    colorDepth: screen.colorDepth,
                    language: navigator.language,
                    languages: navigator.languages
                  });
                })();
                """
                let result = await evaluateJavaScriptResult(operation: operation, timeout: 8)
                    ?? "unavailable"
                FileHandle.standardOutput.write(
                    Data("[cef-smoke] fingerprint privacy: \(result)\n".utf8)
                )
                NSApp.terminate(nil)
            }
            return
        }

        guard let title, !title.isEmpty else { return }
        didStartSmokeCheck = true
        FileHandle.standardOutput.write(Data("[cef-smoke] loaded title: \(title)\n".utf8))
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func schedulePageContextSmokeIfNeeded() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--cef-smoke-test"),
              arguments.contains("--cef-page-context-smoke"),
              !didSchedulePageContextSmoke else { return }
        didSchedulePageContextSmoke = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.startPageContextSmoke()
        }
    }

    private func startPageContextSmoke() {
        guard !didStartSmokeCheck, browser != nil || systemMediaWebView != nil else { return }
        didStartSmokeCheck = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let content = await pageContentContext() ?? ""
            let normalized = content.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            FileHandle.standardOutput.write(
                Data("[cef-smoke] page context: \(normalized.prefix(240))\n".utf8)
            )
            NSApp.terminate(nil)
        }
    }

    func browser(_ browser: CefBrowser, didChangeProgress progress: Double) {
        loadProgress = CGFloat(progress)
    }

    func browser(_ browser: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
        loadingState = PhiTabLoadingState(rawValue: 3)!
    }

    func browser(_ browser: CefBrowser, didChangeFavicon urls: [URL]) {
        let nextURL = urls.first?.absoluteString
        guard nextURL != favIconURL else { return }
        favIconURL = nextURL
        favIconRevision += 1
    }

    func browser(_ browser: CefBrowser, didChangeFullscreen isFullscreen: Bool) {
        isInContentFullscreen = isFullscreen
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        let action = BrowserWindowOpenPolicy.action(for: request)
        AppLogInfo(
            "[CEF] Window-open request disposition=\(request.disposition) " +
            "target=\(request.targetURL?.absoluteString ?? "nil") action=\(action)"
        )
        if action == .allowNativePopup,
           BrowserWindowOpenPolicy.isIdentityProviderURL(request.targetURL),
           let host = request.targetURL?.host {
            AppLogInfo("[CEF] Preserving native identity popup for host=\(host)")
            prepareToIntegrateNextNativePopup()
        }
        if action == .handled, let url = request.targetURL {
            onOpenURLInNewTab?(url, request.disposition != .newBackgroundTab)
        }
        return action
    }

    func browser(_ browser: CefBrowser, didRequestNewTab url: URL?) -> Bool {
        guard let url else { return false }
        guard BrowserWindowOpenPolicy.shouldHandleNewTabInApp(for: url) else {
            // CEF must continue this request so its subsequent popup creation
            // retains the originating page and shared browser session.
            return false
        }
        onOpenURLInNewTab?(url, true)
        return true
    }

    func browserDidGainFocus(_ browser: CefBrowser) {
        isFocused = true
        onActivate?()
    }

    func browserDidClose(_ browser: CefBrowser) {
        if self.browser === browser {
            self.browser = nil
        }
    }

    func browser(
        _ browser: CefBrowser,
        didReceiveConsoleMessage message: String,
        level: CefLogSeverity,
        source: String,
        line: Int
    ) {
        if message.hasPrefix(Self.mediaFallbackPrefix) {
            let rawURL = String(message.dropFirst(Self.mediaFallbackPrefix.count))
            guard let detectedURL = URL(string: rawURL),
                  SystemMediaCompatibilityPolicy.allowsAutomaticFallback(for: detectedURL),
                  detectedURL.host?.caseInsensitiveCompare(
                    URL(string: urlString ?? pendingURL.absoluteString)?.host ?? ""
                  ) == .orderedSame else { return }
            SystemMediaCompatibilityPolicy.rememberDetectedMediaIncompatibility(for: detectedURL)
            switchCurrentPageToSystemMediaEngine(detectedURL)
            return
        }
        let prefix = Self.consoleResultPrefix
        guard message.hasPrefix(prefix) else { return }
        let encodedMessage = String(message.dropFirst(prefix.count))
        let parts = encodedMessage.split(
            separator: ":",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard parts.count == 4,
              let chunkIndex = Int(parts[1]),
              let chunkCount = Int(parts[2]),
              chunkIndex >= 0,
              chunkCount > 0,
              chunkIndex < chunkCount,
              let pending = pendingConsoleEvaluations[String(parts[0])] else { return }

        pending.expectedChunkCount = chunkCount
        pending.chunks[chunkIndex] = String(parts[3])
        guard pending.chunks.count == chunkCount else { return }
        let base64 = (0..<chunkCount).compactMap { pending.chunks[$0] }.joined()
        guard let data = Data(base64Encoded: base64),
              let result = String(data: data, encoding: .utf8) else { return }
        pendingConsoleEvaluations[String(parts[0])] = nil
        pending.timeoutWork?.cancel()
        pending.continuation.resume(returning: result)
    }

    private func evaluateJavaScriptResult(
        operation: String,
        timeout: TimeInterval = 3.5
    ) async -> String? {
        if let systemMediaWebView {
            let script = "return await (async function () { \(operation) })();"
            do {
                let value = try await systemMediaWebView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                if let string = value as? String {
                    return string
                }
                if JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value),
                   let string = String(data: data, encoding: .utf8) {
                    return string
                }
                return String(describing: value)
            } catch {
                return nil
            }
        }
        guard let browser else { return nil }
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
          const bytes = new TextEncoder().encode(result.slice(0, 50000));
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 4096) {
            binary += String.fromCharCode(...bytes.subarray(offset, offset + 4096));
          }
          const encoded = btoa(binary);
          const chunkSize = 6000;
          const chunkCount = Math.max(1, Math.ceil(encoded.length / chunkSize));
          for (let index = 0; index < chunkCount; index += 1) {
            console.info('\(Self.consoleResultPrefix)\(requestID):' + index + ':' + chunkCount + ':' + encoded.slice(index * chunkSize, (index + 1) * chunkSize));
          }
        })();
        """
        return await withCheckedContinuation { continuation in
            let pending = PendingConsoleEvaluation(continuation: continuation)
            let timeoutWork = DispatchWorkItem { [weak self, weak pending] in
                guard let self,
                      let pending,
                      self.pendingConsoleEvaluations.removeValue(forKey: requestID) != nil else { return }
                pending.continuation.resume(returning: nil)
            }
            pending.timeoutWork = timeoutWork
            pendingConsoleEvaluations[requestID] = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            browser.executeJavaScript(script)
        }
    }

    func mediaSessionCookies(for url: URL) async -> [HTTPCookie] {
        if let systemMediaWebView {
            return await withCheckedContinuation { continuation in
                systemMediaWebView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                    let cookies = $0.filter { Self.cookie($0, matches: url) }
                    continuation.resume(returning: cookies)
                }
            }
        }
        return await browser?.cookies(for: url) ?? []
    }

    func mediaDownloadCandidates(for pageURL: URL) async -> [MediaDownloadCandidate] {
        let operation = #"""
        const candidates = [];
        const seen = new Set();
        const add = (value, title, kind, durationSeconds) => {
          if (!value || typeof value !== 'string') return false;
          try {
            const url = new URL(value, location.href);
            if (!['http:', 'https:'].includes(url.protocol) || seen.has(url.href)) return false;
            seen.add(url.href);
            candidates.push({
              url: url.href,
              title: typeof title === 'string' ? title : '',
              kind: kind === 'audio' ? 'audio' : 'video',
              durationSeconds: Number.isFinite(durationSeconds) && durationSeconds > 0
                ? durationSeconds
                : null
            });
            return true;
          } catch (_) {
            return false;
          }
        };
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width >= 120 && rect.height >= 70 &&
            rect.bottom > 0 && rect.right > 0 &&
            rect.top < innerHeight && rect.left < innerWidth;
        };
        const mediaElements = Array.from(document.querySelectorAll('video, audio'))
          .filter(visible)
          .sort((first, second) => {
            const playbackPriority = Number(first.paused) - Number(second.paused);
            if (playbackPriority !== 0) return playbackPriority;
            const firstRect = first.getBoundingClientRect();
            const secondRect = second.getBoundingClientRect();
            return secondRect.width * secondRect.height - firstRect.width * firstRect.height;
          });
        for (let index = 0; index < mediaElements.length; index += 1) {
          const media = mediaElements[index];
          const container = media.closest('article, [role="article"], [data-testid="tweet"]') ||
            media.parentElement;
          const pageLinks = [];
          for (const anchor of container ? container.querySelectorAll('a[href]') : []) {
            const href = anchor.href || '';
            if (/\/status\/\d+|\/watch\?v=|\/shorts\/|\/video\/|\/bangumi\/play\/|\/v\/ac\d+/i.test(href)) {
              pageLinks.push(href);
            }
          }
          const directSources = [media.currentSrc, media.src]
            .concat(Array.from(media.querySelectorAll('source[src]')).map((source) => source.src))
            .filter((value) => typeof value === 'string' && /^https?:/i.test(value));
          const rawTitle = media.getAttribute('aria-label') || media.getAttribute('title') ||
            (container ? (container.innerText || container.textContent || '') : '');
          const title = rawTitle.replace(/\s+/g, ' ').trim().slice(0, 140);
          const kind = media instanceof HTMLAudioElement ? 'audio' : 'video';
          const duration = Number(media.duration);
          const pageURL = pageLinks[0];
          const primaryURL = pageURL || directSources[0];
          if (!add(primaryURL, title, kind, duration) && directSources[0]) {
            add(directSources[0], title, kind, duration);
          }
        }
        const mediaResource = /\.(m3u8|mpd|mp4|m4v|mov|webm|mp3|m4a|aac|ogg|opus)(?:$|[?#])/i;
        if (candidates.length === 0) {
          for (const entry of performance.getEntriesByType('resource').slice().reverse()) {
            if (entry.initiatorType === 'video' || entry.initiatorType === 'audio' ||
                mediaResource.test(entry.name)) {
              const kind = /\.(mp3|m4a|aac|ogg|opus)(?:$|[?#])/i.test(entry.name)
                ? 'audio'
                : 'video';
              add(entry.name, '', kind, null);
            }
          }
        }
        return JSON.stringify(candidates.slice(0, 12));
        """#
        guard let result = await evaluateJavaScriptResult(operation: operation, timeout: 5),
              let data = result.data(using: .utf8),
              let values = try? JSONDecoder().decode([MediaDownloadCandidate].self, from: data) else { return [] }
        var seen = Set<String>()
        return values.compactMap { candidate in
            guard ["http", "https"].contains(candidate.url.scheme?.lowercased() ?? ""),
                  candidate.url != pageURL,
                  seen.insert(candidate.url.absoluteString).inserted else { return nil }
            return candidate
        }
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostMatches = host == domain || host.hasSuffix(".\(domain)")
        guard hostMatches else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" {
            return false
        }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return requestPath.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
    }

    func pageContentContext() async -> String? {
        guard let urlString, !urlString.isNTP else { return nil }
        if let browser {
            if let bridgedContent = await CefBrowserRuntime.shared.requestPageContent(
                browser: browser,
                token: pageContextToken
            ), !bridgedContent.isEmpty {
                return bridgedContent
            }
        }
        let operation = """
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
        return `${semantic.join('\\n')}\\n${raw}`.trim().slice(0, 30000);
        """
        return await evaluateJavaScriptResult(operation: operation, timeout: 5)
    }

    func performBrowserAutomation(_ action: BrowserAutomationAction) async -> BrowserAutomationResult {
        switch action.kind {
        case .inspectPage:
            return await inspectPageForAutomation()
        case .navigate:
            guard let url = action.url else {
                return .init(succeeded: false, message: "A valid URL is required.")
            }
            navigate(toURL: url.absoluteString)
            return .init(succeeded: true, message: "Navigation started. Inspect the page again after it loads.")
        case .click:
            let target = BrowserAutomationTarget(action: action)
            guard target.isSpecified else {
                return .init(succeeded: false, message: "An element ref, CSS selector, or index is required.")
            }
            return await clickAutomationTarget(target)
        case .typeText:
            let target = BrowserAutomationTarget(action: action)
            guard target.isSpecified, let text = action.text else {
                return .init(succeeded: false, message: "An element target and text are required.")
            }
            return await typeAutomationText(text, into: target)
        case .pressKey:
            let target = BrowserAutomationTarget(action: action)
            guard target.isSpecified, let key = action.key else {
                return .init(succeeded: false, message: "An element target and key are required.")
            }
            return await pressAutomationKey(key, on: target)
        case .waitForElement:
            let target = BrowserAutomationTarget(action: action)
            guard target.isSpecified else {
                return .init(succeeded: false, message: "An element ref, CSS selector, or index is required.")
            }
            return await waitForAutomationElement(
                target,
                milliseconds: action.milliseconds ?? 3_000
            )
        case .inspectVisualPage:
            return await captureVisualAutomationPage()
        case .visualClick:
            guard let point = BrowserAutomationPoint(x: action.x, y: action.y) else {
                return .init(
                    succeeded: false,
                    message: "Normalized x and y coordinates from 0 through 1000 are required."
                )
            }
            return await clickVisualAutomationPoint(point)
        case .scroll:
            guard browser != nil || systemMediaWebView != nil else {
                return .init(succeeded: false, message: "The page is not ready.")
            }
            let pixels = max(-1200, min(1200, action.pixels ?? 0))
            let operation = "window.scrollBy({ top: \(pixels), behavior: 'smooth' }); return JSON.stringify({ ok: true, message: 'Scrolled \(pixels) pixels.' });"
            let response = await evaluateJavaScriptResult(operation: operation)
            return automationResult(response)
        case .goBack:
            guard canGoBack else {
                return .init(succeeded: false, message: "There is no previous page in this tab.")
            }
            goBack()
            return .init(succeeded: true, message: "Went back. Inspect the page again after it loads.")
        case .reload:
            reload()
            return .init(succeeded: true, message: "Reload started. Inspect the page again after it loads.")
        case .openTab:
            guard let url = action.url else {
                return .init(succeeded: false, message: "A valid URL is required.")
            }
            onOpenURLInNewTab?(url, true)
            return .init(succeeded: true, message: "Opened the URL in a new foreground tab.")
        }
    }

    private func captureVisualAutomationPage() async -> BrowserAutomationResult {
        let route = VisiblePageCaptureRoute.active(
            hasSystemMediaPage: systemMediaWebView != nil
        )
        let image: CGImage?
        switch route {
        case .systemMedia:
            image = await captureSystemMediaPagePixels()
        case .chromium:
            image = await captureChromiumPagePixels()
        }

        guard let image,
              let jpeg = compressedAutomationScreenshot(image) else {
            return .init(
                succeeded: false,
                message: "The visible page could not be captured. Keep the tab visible and try again."
            )
        }
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        return .init(
            succeeded: true,
            message: "Captured the visible page at \(image.width) by \(image.height) pixels. Use normalized coordinates from 0 through 1000 with the origin at the top-left.",
            imageDataURL: dataURL
        )
    }

    private func captureSystemMediaPagePixels() async -> CGImage? {
        guard let webView = systemMediaWebView else { return nil }
        if let image = captureOnScreenPixels(of: webView) {
            return image
        }
        let snapshot = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
        return snapshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func captureChromiumPagePixels() async -> CGImage? {
        if let overlay = chromeBrowser?.nsWindow,
           overlay.isVisible,
           let contentView = overlay.contentView,
           let image = captureOnScreenPixels(of: contentView) {
            return image
        }
        guard let nativeScreenshot = await browser?.captureVisiblePageScreenshot(),
              let source = CGImageSourceCreateWithData(nativeScreenshot as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func captureOnScreenPixels(of view: NSView) -> CGImage? {
        guard let snapshot = WebContentSnapshotter.captureOnScreen(
            view,
            resolution: .bestResolution
        ) else {
            return nil
        }
        return snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func compressedAutomationScreenshot(_ source: CGImage) -> Data? {
        let maximumSize = CGSize(width: 1_600, height: 1_000)
        let scale = min(
            1,
            maximumSize.width / CGFloat(source.width),
            maximumSize.height / CGFloat(source.height)
        )
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: resized).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.72]
        )
    }

    private func clickVisualAutomationPoint(
        _ point: BrowserAutomationPoint
    ) async -> BrowserAutomationResult {
        guard let browser,
              let viewportSize = chromeBrowser?.nsWindow?.contentView?.bounds.size,
              viewportSize.width > 1,
              viewportSize.height > 1 else {
            return .init(succeeded: false, message: "The page is not ready.")
        }

        let descriptorOperation = """
        const x = window.innerWidth * \(point.x) / 1000;
        const y = window.innerHeight * \(point.y) / 1000;
        const element = document.elementFromPoint(x, y);
        if (!element) return JSON.stringify({ found: false });
        const label = (element.getAttribute('aria-label') || element.getAttribute('title') || element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 240);
        const type = element instanceof HTMLInputElement || element instanceof HTMLButtonElement ? element.type : null;
        return JSON.stringify({ found: true, label, type });
        """
        if let descriptorJSON = await evaluateJavaScriptResult(operation: descriptorOperation),
        let descriptor = try? JSONDecoder().decode(
            AutomationTarget.self,
            from: Data(descriptorJSON.utf8)
        ),
        descriptor.found,
        requiresConfirmation(descriptor),
        !confirmAutomationClick(label: descriptor.label) {
            return .init(succeeded: false, message: "The user cancelled this click.")
        }

        return dispatchNativeAutomationClick(
            point,
            viewportSize: viewportSize,
            message: "Clicked the visually located page point."
        )
    }

    private func dispatchNativeAutomationClick(
        _ point: BrowserAutomationPoint,
        viewportSize explicitViewportSize: CGSize? = nil,
        message: String
    ) -> BrowserAutomationResult {
        guard let browser,
              let viewportSize = explicitViewportSize
                ?? chromeBrowser?.nsWindow?.contentView?.bounds.size,
              viewportSize.width > 1,
              viewportSize.height > 1 else {
            return .init(succeeded: false, message: "The page is not ready.")
        }
        let viewportPoint = point.point(in: viewportSize)
        browser.setFocus(true)
        browser.sendMouseMove(to: viewportPoint, modifiers: 0)
        browser.sendMouseDown(
            at: viewportPoint,
            button: .left,
            clickCount: 1,
            modifiers: 0
        )
        browser.sendMouseUp(
            at: viewportPoint,
            button: .left,
            clickCount: 1,
            modifiers: 0
        )
        return .init(succeeded: true, message: message)
    }

    private func inspectPageForAutomation() async -> BrowserAutomationResult {
        guard let browser else {
            return .init(succeeded: false, message: "The page is not ready.")
        }
        let operation = """
        const visible = (element) => {
          if (element.hidden || element.style?.display === 'none' || element.style?.visibility === 'hidden') return false;
          const rect = element.getBoundingClientRect();
          if (rect.width <= 1 || rect.height <= 1 || rect.bottom < 0 || rect.top > window.innerHeight || rect.right < 0 || rect.left > window.innerWidth) return false;
          const style = window.getComputedStyle(element);
          return style.visibility !== 'hidden' && style.display !== 'none';
        };
        const stableSelector = (element) => {
          if (element.id) {
            const candidate = `#${CSS.escape(element.id)}`;
            if (document.getElementById(element.id) === element) return candidate;
          }
          for (const name of ['data-testid', 'data-test', 'data-automation-id']) {
            const value = element.getAttribute(name);
            if (!value) continue;
            const candidate = `${element.tagName.toLowerCase()}[${name}="${CSS.escape(value)}"]`;
            try {
              if (document.querySelector(candidate) === element) return candidate;
            } catch (_) {}
          }
          const role = element.getAttribute('role');
          const ariaLabel = element.getAttribute('aria-label');
          if (role && ariaLabel) {
            const candidate = `[role="${CSS.escape(role)}"][aria-label="${CSS.escape(ariaLabel)}"]`;
            try {
              if (document.querySelector(candidate) === element) return candidate;
            } catch (_) {}
          }
          const path = [];
          let current = element;
          while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.body && path.length < 7) {
            let part = current.tagName.toLowerCase();
            const siblings = Array.from(current.parentElement?.children || []).filter((sibling) => sibling.tagName === current.tagName);
            if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
            path.unshift(part);
            current = current.parentElement;
          }
          return path.join(' > ');
        };
        const sanitizedHTML = (element) => {
          const clone = element.cloneNode(false);
          for (const attribute of Array.from(clone.attributes || [])) {
            const name = attribute.name.toLowerCase();
            if (name === 'value' || name === 'srcdoc' || name === 'data-astra-ai-index' || name === 'data-astra-ai-ref' || name.startsWith('on')) {
              clone.removeAttribute(attribute.name);
            } else if (attribute.value.length > 240) {
              clone.setAttribute(attribute.name, `${attribute.value.slice(0, 240)}…`);
            }
          }
          return clone.outerHTML.slice(0, 500);
        };
        document.querySelectorAll('[data-astra-ai-index]').forEach((element) => element.removeAttribute('data-astra-ai-index'));
        const interactiveSelector = 'a[href],button,input,textarea,select,[contenteditable="true"],[role="button"],[role="checkbox"],[role="radio"],[role="menuitem"],[role="menuitemcheckbox"],[role="option"],[role="tab"],[role="combobox"],[role="textbox"]';
        const candidates = document.querySelectorAll(interactiveSelector);
        const elements = [];
        let estimatedLength = 0;
        const scanDeadline = performance.now() + 900;
        for (let candidateIndex = 0; candidateIndex < candidates.length && elements.length < 120; candidateIndex += 1) {
          if (performance.now() > scanDeadline) break;
          const element = candidates[candidateIndex];
          if (!visible(element)) continue;
          const index = elements.length;
          element.setAttribute('data-astra-ai-index', String(index));
          let ref = element.getAttribute('data-astra-ai-ref');
          if (!ref) {
            ref = `e-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
            element.setAttribute('data-astra-ai-ref', ref);
          }
          const label = (element.getAttribute('aria-label') || element.getAttribute('title') || element.getAttribute('placeholder') || element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 180);
          const href = element.href && /^https?:/i.test(element.href) ? element.href.slice(0, 500) : null;
          const inputType = element instanceof HTMLInputElement || element instanceof HTMLButtonElement ? (element.type || 'text') : null;
          const descriptor = {
            index,
            ref,
            selector: stableSelector(element).slice(0, 500),
            html: sanitizedHTML(element),
            tag: element.tagName.toLowerCase(),
            role: element.getAttribute('role'),
            type: inputType,
            label,
            href,
            aria: {
              checked: element.getAttribute('aria-checked'),
              expanded: element.getAttribute('aria-expanded'),
              pressed: element.getAttribute('aria-pressed'),
              selected: element.getAttribute('aria-selected'),
              disabled: element.getAttribute('aria-disabled'),
            },
            disabled: Boolean(element.disabled),
          };
          estimatedLength += JSON.stringify(descriptor).length;
          if (estimatedLength > 32_000) break;
          elements.push(descriptor);
        }
        const pageRoot = document.querySelector('main,[role="main"],article') || document.body;
        const pageText = pageRoot?.textContent || '';
        return JSON.stringify({ ok: true, title: document.title, url: location.href, viewport: { scrollY: Math.round(window.scrollY), height: window.innerHeight }, text: pageText.replace(/\\s+/g, ' ').trim().slice(0, 6000), elements });
        """
        guard let response = await evaluateJavaScriptResult(
            operation: operation,
            timeout: 5
        ) else {
            if let pageText = await pageContentContext(),
               let fallback = Self.partialInspectionJSON(
                title: title ?? "",
                url: urlString ?? "",
                text: pageText
               ) {
                return .init(succeeded: true, message: fallback)
            }
            return .init(succeeded: false, message: "The page did not respond to inspection.")
        }
        return .init(succeeded: true, message: response)
    }

    static func partialInspectionJSON(title: String, url: String, text: String) -> String? {
        let payload: [String: Any] = [
            "ok": true,
            "partial": true,
            "message": "Interactive element inspection timed out; readable page content is available.",
            "title": title,
            "url": url,
            "text": String(text.prefix(12_000)),
            "elements": [],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return encoded
    }

    private struct AutomationTarget: Decodable {
        let found: Bool
        let label: String?
        let type: String?
        let x: Int?
        let y: Int?
    }

    private func clickAutomationTarget(_ target: BrowserAutomationTarget) async -> BrowserAutomationResult {
        guard let browser else {
            return .init(succeeded: false, message: "The page is not ready.")
        }
        guard let resolver = target.javaScriptResolver() else {
            return .init(succeeded: false, message: "The element target is invalid.")
        }
        let descriptorOperation = """
        \(resolver)
        if (targetError) return JSON.stringify({ found: false, message: targetError });
        if (!element) return JSON.stringify({ found: false });
        element.scrollIntoView({ block: 'center', inline: 'center' });
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return JSON.stringify({ found: false });
        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;
        const label = (element.getAttribute('aria-label') || element.getAttribute('title') || element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 240);
        const type = element instanceof HTMLInputElement || element instanceof HTMLButtonElement ? element.type : null;
        return JSON.stringify({
          found: true, label, tag: element.tagName.toLowerCase(),
          role: element.getAttribute('role'), type,
          insideForm: Boolean(element.closest('form')),
          x: Math.round(centerX * 1000 / window.innerWidth),
          y: Math.round(centerY * 1000 / window.innerHeight)
        });
        """
        guard let descriptorJSON = await evaluateJavaScriptResult(operation: descriptorOperation),
        let descriptor = try? JSONDecoder().decode(AutomationTarget.self, from: Data(descriptorJSON.utf8)),
        descriptor.found else {
            return .init(succeeded: false, message: "The target is no longer available. Inspect the page again.")
        }

        if requiresConfirmation(descriptor), !confirmAutomationClick(label: descriptor.label) {
            return .init(succeeded: false, message: "The user cancelled this click.")
        }

        guard let point = BrowserAutomationPoint(x: descriptor.x, y: descriptor.y) else {
            return .init(
                succeeded: false,
                message: "The target has no valid clickable position. Inspect the page again."
            )
        }
        return dispatchNativeAutomationClick(
            point,
            message: "Sent a native click to the requested DOM element."
        )
    }

    private func typeAutomationText(_ text: String, into target: BrowserAutomationTarget) async -> BrowserAutomationResult {
        guard let browser else {
            return .init(succeeded: false, message: "The page is not ready.")
        }
        guard let resolver = target.javaScriptResolver() else {
            return .init(succeeded: false, message: "The element target is invalid.")
        }
        guard let encodedText = try? String(
            decoding: JSONEncoder().encode(text),
            as: UTF8.self
        ) else {
            return .init(succeeded: false, message: "The text could not be encoded.")
        }
        let operation = """
        \(resolver)
        if (targetError) return JSON.stringify({ ok: false, message: targetError });
        if (!element) return JSON.stringify({ ok: false, message: 'The target is no longer available. Inspect the page again.' });
        const blockedTypes = new Set(['password']);
        const autocomplete = (element.getAttribute('autocomplete') || '').toLowerCase();
        if (blockedTypes.has((element.type || '').toLowerCase()) || /password|one-time-code|cc-|credit-card/.test(autocomplete)) {
          return JSON.stringify({ ok: false, message: 'Astra Browser will not let AI enter passwords, verification codes, or payment information.' });
        }
        if (!(element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element.isContentEditable)) {
          return JSON.stringify({ ok: false, message: 'The target is not editable.' });
        }
        element.focus();
        const text = \(encodedText);
        if (element.isContentEditable) {
          element.textContent = text;
        } else {
          const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(element, text); else element.value = text;
        }
        element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        return JSON.stringify({ ok: true, message: 'Entered text without submitting the form.' });
        """
        return automationResult(await evaluateJavaScriptResult(operation: operation))
    }

    private func pressAutomationKey(_ rawKey: String, on target: BrowserAutomationTarget) async -> BrowserAutomationResult {
        guard let browser else {
            return .init(succeeded: false, message: "The page is not ready.")
        }
        guard let resolver = target.javaScriptResolver() else {
            return .init(succeeded: false, message: "The element target is invalid.")
        }
        let supportedKeys: [String: String] = [
            "enter": "Enter",
            "escape": "Escape",
            "tab": "Tab",
            "arrowup": "ArrowUp",
            "arrowdown": "ArrowDown",
            "arrowleft": "ArrowLeft",
            "arrowright": "ArrowRight",
            "home": "Home",
            "end": "End",
        ]
        guard let key = supportedKeys[rawKey.lowercased()] else {
            return .init(succeeded: false, message: "That key is not supported.")
        }
        guard let encodedKey = try? String(
            decoding: JSONEncoder().encode(key),
            as: UTF8.self
        ) else {
            return .init(succeeded: false, message: "The key could not be encoded.")
        }
        let operation = """
        \(resolver)
        if (targetError) return JSON.stringify({ ok: false, message: targetError });
        if (!element) return JSON.stringify({ ok: false, message: 'The target is no longer available. Inspect the page again.' });
        element.focus();
        const key = \(encodedKey);
        const keyCode = { Enter: 13, Escape: 27, Tab: 9, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35 }[key] || 0;
        const options = { key, code: key, keyCode, which: keyCode, bubbles: true, cancelable: true };
        const accepted = element.dispatchEvent(new KeyboardEvent('keydown', options));
        element.dispatchEvent(new KeyboardEvent('keypress', options));
        element.dispatchEvent(new KeyboardEvent('keyup', options));
        return JSON.stringify({ ok: true, message: accepted ? `Pressed ${key}. Inspect the page again before another interaction.` : `The page handled ${key}. Inspect the page again.` });
        """
        return automationResult(await evaluateJavaScriptResult(operation: operation))
    }

    private func waitForAutomationElement(
        _ target: BrowserAutomationTarget,
        milliseconds: Int
    ) async -> BrowserAutomationResult {
        guard let browser else {
            return .init(succeeded: false, message: "The page is not ready.")
        }
        guard let resolver = target.javaScriptResolver() else {
            return .init(succeeded: false, message: "The element target is invalid.")
        }
        let timeout = max(0, min(8_000, milliseconds))
        let operation = """
        const resolveTarget = () => {
          \(resolver)
          return { element, targetError };
        };
        const visible = (candidate) => {
          if (!candidate) return false;
          const style = window.getComputedStyle(candidate);
          const rect = candidate.getBoundingClientRect();
          return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 1 && rect.height > 1;
        };
        const deadline = Date.now() + \(timeout);
        while (true) {
          const resolved = resolveTarget();
          if (resolved.targetError) return JSON.stringify({ ok: false, message: resolved.targetError });
          if (visible(resolved.element)) {
            const element = resolved.element;
            let ref = element.getAttribute('data-astra-ai-ref');
            if (!ref) {
              ref = `e-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
              element.setAttribute('data-astra-ai-ref', ref);
            }
            const label = (element.getAttribute('aria-label') || element.getAttribute('title') || element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 180);
            const descriptor = {
              ref,
              tag: element.tagName.toLowerCase(),
              role: element.getAttribute('role'),
              label,
              ariaChecked: element.getAttribute('aria-checked'),
              ariaExpanded: element.getAttribute('aria-expanded'),
              disabled: Boolean(element.disabled),
            };
            return JSON.stringify({ ok: true, message: `Element is ready: ${JSON.stringify(descriptor)}` });
          }
          if (Date.now() >= deadline) break;
          await new Promise((resolve) => setTimeout(resolve, 200));
        }
        return JSON.stringify({ ok: false, message: 'The element did not become visible before the timeout.' });
        """
        return automationResult(await evaluateJavaScriptResult(
            operation: operation,
            timeout: (Double(timeout) / 1_000) + 2
        ))
    }

    private func requiresConfirmation(_ target: AutomationTarget) -> Bool {
        BrowserAutomationInteractionPolicy.requiresConfirmation(controlType: target.type)
    }

    private func confirmAutomationClick(label: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "chat.browserControl.confirmation.title",
            value: "Allow AI to click this control?",
            comment: "Browser control confirmation - Title shown before AI clicks a page control that can change external state"
        )
        let target = label?.isEmpty == false ? label! : NSLocalizedString(
            "chat.browserControl.confirmation.unnamedTarget",
            value: "Unnamed page control",
            comment: "Browser control confirmation - Fallback name for a page control without an accessible label"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "chat.browserControl.confirmation.message",
                value: "ZenMux wants to click “%@”. Review the page before allowing the action.",
                comment: "Browser control confirmation - Message naming the page control that ZenMux wants to click"
            ),
            target
        )
        alert.addButton(withTitle: NSLocalizedString(
            "chat.browserControl.confirmation.allowButton",
            value: "Allow Click",
            comment: "Browser control confirmation - Button that permits the requested page click"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "chat.browserControl.confirmation.cancelButton",
            value: "Cancel",
            comment: "Browser control confirmation - Button that rejects the requested page click"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct AutomationResponsePayload: Decodable {
        let ok: Bool
        let message: String
    }

    private func automationResult(_ rawValue: String?) -> BrowserAutomationResult {
        guard let rawValue,
              let payload = try? JSONDecoder().decode(
                AutomationResponsePayload.self,
                from: Data(rawValue.utf8)
              ) else {
            return .init(succeeded: false, message: "The page did not respond to the browser action.")
        }
        return .init(succeeded: payload.ok, message: payload.message)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadingState = PhiTabLoadingState(rawValue: 2)!
        loadProgress = 0
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateSystemMediaPageState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        loadingState = PhiTabLoadingState(rawValue: 0)!
        loadProgress = 1
        updateSystemMediaPageState(webView)
        runSmokeCheckIfReady()
        if CommandLine.arguments.contains("--cef-smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.updateSystemMediaPageState(webView)
                self.runSmokeCheckIfReady()
            }
        }
        webView.evaluateJavaScript(
            "document.querySelector('link[rel~=icon]')?.href || null"
        ) { [weak self] value, _ in
            guard let self, let iconURL = value as? String, !iconURL.isEmpty else { return }
            MainActor.assumeIsolated {
                guard self.favIconURL != iconURL else { return }
                self.favIconURL = iconURL
                self.favIconRevision += 1
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        loadingState = PhiTabLoadingState(rawValue: 3)!
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        loadingState = PhiTabLoadingState(rawValue: 3)!
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let destination = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame == nil,
           BrowserWindowOpenPolicy.isIdentityProviderURL(destination) {
            // Let WKUIDelegate create an Astra-owned popup so OAuth retains
            // window.opener and the current profile's persistent data store.
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame == nil {
            onOpenURLInNewTab?(destination, true)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           !shouldUsePersistentWebKit(for: destination) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.navigate(toURL: destination.absoluteString)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let destination = navigationAction.request.url else { return nil }
        if BrowserWindowOpenPolicy.isIdentityProviderURL(destination) {
            let popupHost = SystemMediaPopupHost(configuration: configuration)
            let identifier = ObjectIdentifier(popupHost)
            popupHost.onClose = { [weak self] in
                self?.systemMediaPopupHosts.removeValue(forKey: identifier)
            }
            systemMediaPopupHosts[identifier] = popupHost
            popupHost.show(relativeTo: hostView.window)
            return popupHost.webView
        }
        onOpenURLInNewTab?(destination, true)
        return nil
    }

    private func updateSystemMediaPageState(_ webView: WKWebView) {
        guard let pageURL = webView.url else { return }
        pendingURL = pageURL
        urlString = pageURL.absoluteString
        title = webView.title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        securityInfo = [
            "securityLevel": pageURL.scheme?.lowercased() == "https" ? 3 : 0,
            "hasCertificate": pageURL.scheme?.lowercased() == "https",
        ]
    }
}
