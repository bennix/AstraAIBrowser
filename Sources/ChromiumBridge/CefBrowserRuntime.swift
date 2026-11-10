// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CefKit
import Darwin
import SystemConfiguration

enum BrowserProxyPolicy {
    static let privacyRequiredKey = "browserPrivacyProxyRequired"
    static let privacyEndpoint = "127.0.0.1:7891"
    static let enabledKey = "browserAutoProxyEnabled"
    static let localEndpointKey = "browserAutoProxyLocalEndpoint"
    static let localEndpoint = "127.0.0.1:7890"
    private static let startupProxyHealthy = probe(proxy: true)

    enum Detection: Equatable {
        case system
        case direct
        case local
        case unavailable
    }

    static func route(directReachable: Bool, proxyReachable: Bool) -> Detection {
        if proxyReachable { return .local }
        return directReachable ? .direct : .unavailable
    }

    static func cefProxyServer(for endpoint: String) -> String {
        endpoint == privacyEndpoint ? "http://\(endpoint)" : "http://\(endpoint),direct://"
    }

    static func systemProxyIsEnabled(_ proxies: [String: Any]) -> Bool {
        [
            kSCPropNetProxiesHTTPEnable,
            kSCPropNetProxiesHTTPSEnable,
            kSCPropNetProxiesSOCKSEnable,
            kSCPropNetProxiesProxyAutoConfigEnable,
            kSCPropNetProxiesProxyAutoDiscoveryEnable
        ].contains { (proxies[$0 as String] as? NSNumber)?.boolValue == true }
    }

    static func systemProxyIsEnabled() -> Bool {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return systemProxyIsEnabled(proxies)
    }

    static func effectiveLocalEndpoint(defaults: UserDefaults = .standard) -> String? {
        // A required proxy must stay selected when unavailable, so requests fail
        // instead of silently disclosing the direct network address.
        if defaults.bool(forKey: privacyRequiredKey) { return privacyEndpoint }
        guard defaults.bool(forKey: enabledKey), !systemProxyIsEnabled(),
              defaults.string(forKey: localEndpointKey) == localEndpoint else { return nil }
        let endpoint = resolvedLocalEndpoint(
            enabled: true,
            systemProxyEnabled: false,
            savedEndpoint: localEndpoint,
            localReachable: localPortIsOpen(),
            proxyHealthy: startupProxyHealthy
        )
        if endpoint == nil { defaults.removeObject(forKey: localEndpointKey) }
        return endpoint
    }

    static func resolvedLocalEndpoint(
        enabled: Bool,
        systemProxyEnabled: Bool,
        savedEndpoint: String?,
        localReachable: Bool,
        proxyHealthy: Bool = true
    ) -> String? {
        guard enabled, !systemProxyEnabled,
              savedEndpoint == localEndpoint, localReachable, proxyHealthy else { return nil }
        return localEndpoint
    }

    private static func probe(proxy: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // An open listener may fail CONNECT or TLS for the destination.
        process.arguments = ["--silent", "--show-error", "--output", "/dev/null"]
            + (proxy
                ? ["--noproxy", "", "--proxy", "http://\(localEndpoint)"]
                : ["--noproxy", "*"])
            + ["--connect-timeout", "2", "--max-time", "5", "--head", "https://x.com/"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func localPortIsOpen() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(7890).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func refresh(defaults: UserDefaults = .standard) async -> Detection {
        guard defaults.bool(forKey: enabledKey) else {
            defaults.removeObject(forKey: localEndpointKey)
            return .unavailable
        }
        if systemProxyIsEnabled() {
            defaults.removeObject(forKey: localEndpointKey)
            return .system
        }
        let detection = await Task.detached(priority: .utility) {
            let directReachable = probe(proxy: false)
            return route(
                directReachable: directReachable,
                proxyReachable: localPortIsOpen() && probe(proxy: true)
            )
        }.value
        if detection == .local {
            defaults.set(localEndpoint, forKey: localEndpointKey)
        } else {
            defaults.removeObject(forKey: localEndpointKey)
        }
        return detection
    }
}

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

/// Keeps authentication challenges on native browser surfaces because
/// anti-abuse SDKs validate consistency across canvas, WebGL, audio, fonts,
/// and pointer input. Other pages continue to receive fingerprint privacy.
enum CefSecurityChallengeCompatibilityPolicy {
    /// Sites whose security SDKs run inline on authenticated product pages,
    /// not only on a dedicated login or challenge route. These hosts must use
    /// one consistent set of native browser surfaces for the whole origin so
    /// a challenge opened after navigation sees the same fingerprint values.
    private static let inlineChallengeHosts = Set([
        "developer.amd.com.cn",
        "claude.ai",
        "www.claude.ai",
        // Authentication can be reached through client-side navigation after
        // document-start scripts have already run on the landing page.
        "zenmux.ai",
        "www.zenmux.ai"
    ])

    private static let authenticationPathSegments = Set([
        "auth",
        "authenticate",
        "authentication",
        "captcha",
        "challenge",
        "login",
        "oauth",
        "recaptcha",
        "sign-in",
        "signin",
        "sso",
        "verification",
        "verify"
    ])

    private static let challengeHostLabels = Set([
        "auth",
        "captcha",
        "challenge",
        "challenges",
        "login",
        "oauth",
        "recaptcha",
        "signin",
        "sso",
        "verification",
        "verify"
    ])

    static func shouldUseNativeBrowserSurfaces(host: String, path: String) -> Bool {
        let normalizedHost = host.lowercased()
        let normalizedPath = path.lowercased()
        if normalizedPath == "/cdn-cgi/challenge-platform"
            || normalizedPath.hasPrefix("/cdn-cgi/challenge-platform/") {
            return true
        }
        if normalizedHost == "accounts.youtube.com"
            || normalizedHost.hasPrefix("accounts.google.") {
            return true
        }
        if inlineChallengeHosts.contains(normalizedHost) {
            return true
        }

        let hostLabels = normalizedHost
            .split(separator: ".")
            .map(String.init)
        if hostLabels.contains(where: challengeHostLabels.contains) {
            return true
        }

        let pathSegments = path
            .lowercased()
            .split(separator: "/")
            .map(String.init)
        return pathSegments.contains(where: authenticationPathSegments.contains)
    }

    static let javaScript = #"""
    (() => {
      const inlineChallengeHosts = new Set([
        "developer.amd.com.cn",
        "claude.ai",
        "www.claude.ai",
        "zenmux.ai",
        "www.zenmux.ai"
      ]);
      const authenticationPathSegments = new Set([
        "auth", "authenticate", "authentication", "captcha", "challenge",
        "login", "oauth", "recaptcha", "sign-in", "signin", "sso",
        "verification", "verify"
      ]);
      const challengeHostLabels = new Set([
        "auth", "captcha", "challenge", "challenges", "recaptcha",
        "login", "oauth", "signin", "sso", "verification", "verify"
      ]);

      const isSecurityChallengeLocation = (locationValue) => {
        if (!locationValue) {
          return false;
        }
        const normalizedHost = String(locationValue.hostname || "").toLowerCase();
        const normalizedPath = String(locationValue.pathname || "").toLowerCase();
        if (normalizedPath === "/cdn-cgi/challenge-platform"
            || normalizedPath.startsWith("/cdn-cgi/challenge-platform/")) return true;
        if (normalizedHost === "accounts.youtube.com"
            || normalizedHost.startsWith("accounts.google.")) {
          return true;
        }
        if (inlineChallengeHosts.has(normalizedHost)) {
          return true;
        }
        const hostLabels = normalizedHost
          .split(".")
          .filter(Boolean);
        if (hostLabels.some((label) => challengeHostLabels.has(label))) {
          return true;
        }
        const pathSegments = String(locationValue.pathname || "")
          .toLowerCase()
          .split("/")
          .filter(Boolean);
        return pathSegments.some((segment) => authenticationPathSegments.has(segment));
      };

      let usesNativeSurfaces = isSecurityChallengeLocation(globalThis.location);
      if (!usesNativeSurfaces) {
        try {
          usesNativeSurfaces = isSecurityChallengeLocation(globalThis.top?.location);
        } catch (_) {
          // Cross-origin frames are classified by their own challenge host.
        }
      }
      if (!usesNativeSurfaces) {
        return;
      }

      Object.defineProperty(globalThis, "__astraUsesNativeSecurityChallengeSurfaces", {
        value: true,
        configurable: false,
        enumerable: false,
        writable: false
      });
    })();
    """#
}

enum CefWebStoreExtensionDownloadPolicy {
    private static let trustedHosts = Set([
        "clients2.google.com",
        "clients2.googleusercontent.com",
        "chromewebstore.google.com"
    ])

    static func extensionID(fileName: String, sourceURL: String) -> String? {
        guard let url = URL(string: sourceURL),
              let host = url.host?.lowercased(),
              trustedHosts.contains(host),
              fileName.lowercased().hasSuffix(".crx") else {
            return nil
        }
        let candidate = fileName
            .lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == "." || $0 == "-" })
            .first
            .map(String.init) ?? ""
        guard candidate.count == 32,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 97 && scalar.value <= 112
              }) else {
            return nil
        }
        return candidate
    }
}

enum CefWebRTCPrivacyPolicy {
    static let commandLineSwitch = "webrtc-ip-handling-policy"
    static let forceCommandLineSwitch = "force-webrtc-ip-handling-policy"
    static let requiredValue = "disable_non_proxied_udp"

    static func apply(to commandLine: CefCommandLine) {
        // Cover both Chrome-runtime profiles and Content-layer renderers. The
        // force switch is process-wide, so isolated and incognito profiles
        // cannot silently fall back to unrestricted direct UDP.
        commandLine.appendSwitch(commandLineSwitch, value: requiredValue)
        commandLine.appendSwitch(forceCommandLineSwitch, value: requiredValue)
    }
}

enum CefBrowserAccountPrivacyPolicy {
    static let disableSyncSwitch = "disable-sync"

    static func apply(to configuration: inout CefConfiguration) {
        configuration.extraCommandLineSwitches.updateValue(nil, forKey: disableSyncSwitch)
    }

    static func prepareProfile(
        at rootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        // Chromium browser sign-in is separate from website authentication.
        // Seed the request-context preference before CEF reads the profile so
        // Gmail and YouTube cookies remain usable without attaching the Google
        // account to Astra or activating browser sync.
        let defaultProfileURL = rootURL.appendingPathComponent("Default", isDirectory: true)
        let preferencesURL = defaultProfileURL.appendingPathComponent("Preferences", isDirectory: false)
        try fileManager.createDirectory(
            at: defaultProfileURL,
            withIntermediateDirectories: true
        )

        var preferences: [String: Any] = [:]
        if fileManager.fileExists(atPath: preferencesURL.path) {
            let data = try Data(contentsOf: preferencesURL)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            preferences = decoded
        }

        var signin = preferences["signin"] as? [String: Any] ?? [:]
        signin["allowed"] = false
        preferences["signin"] = signin

        let data = try JSONSerialization.data(withJSONObject: preferences)
        try data.write(to: preferencesURL, options: .atomic)
    }
}

enum BrowserSecureDNSPolicy {
    static let enabledKey = "browserSecureDNSEnabled"
    static let template = "https://cloudflare-dns.com/dns-query"

    static func prepareLocalState(at rootURL: URL, enabled: Bool) throws {
        let url = rootURL.appendingPathComponent("Local State")
        var state: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            state = existing
        }
        var dns = state["dns_over_https"] as? [String: Any] ?? [:]
        dns["mode"] = enabled ? "secure" : "off"
        dns["templates"] = enabled ? template : ""
        state["dns_over_https"] = dns
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state).write(to: url, options: .atomic)
    }
}

enum BrowserNetworkLanguagePolicy {
    static func preferredLanguages(forCountryCode countryCode: String?) -> String {
        var languages = ["en-US", "en", "zh-CN", "zh"]
        if let countryCode,
           let locale = BrowserNetworkLanguagePolicy.locale(forCountryCode: countryCode) {
            let language = locale.split(separator: "-").first.map(String.init) ?? locale
            if !["en", "zh"].contains(language) {
                for value in [locale, language] where !languages.contains(value) {
                    languages.append(value)
                }
            }
        }
        return languages.joined(separator: ",")
    }


    private static let cachedCountryCodeKey = "BrowserNetworkLanguageCountryCode"
    private static let cachedCountryCodeDateKey = "BrowserNetworkLanguageCountryCodeDate"
    private static let maximumCachedCountryCodeAge: TimeInterval = 60 * 60

    static func resolvedLocale(
        fallbackLocale: String,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        lookup: () -> PublicIPv4Location?
    ) -> String {
        if let location = lookup() {
            defaults.set(location.countryCode, forKey: cachedCountryCodeKey)
            defaults.set(now, forKey: cachedCountryCodeDateKey)
            return locale(forCountryCode: location.countryCode) ?? fallbackLocale
        }

        if let cachedCountryCode = defaults.string(forKey: cachedCountryCodeKey),
           let cachedDate = defaults.object(forKey: cachedCountryCodeDateKey) as? Date,
           now.timeIntervalSince(cachedDate) >= 0,
           now.timeIntervalSince(cachedDate) <= maximumCachedCountryCodeAge,
           let cachedLocale = locale(forCountryCode: cachedCountryCode) {
            return cachedLocale
        }
        return fallbackLocale
    }

    static func locale(forCountryCode rawCountryCode: String) -> String? {
        let countryCode = rawCountryCode.uppercased()
        guard countryCode.count == 2,
              countryCode.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 65 && scalar.value <= 90
              }),
              countryCode != "ZZ" else {
            return nil
        }

        let language: String
        switch countryCode {
        case "CN": language = "zh"
        case "TW": language = "zh-Hant"
        case "HK", "MO": language = "zh-Hant"
        case "JP": language = "ja"
        case "KR": language = "ko"
        case "TH": language = "th"
        case "VN": language = "vi"
        case "ID": language = "id"
        case "MY": language = "ms"
        case "PH": language = "fil"
        case "KH": language = "km"
        case "LA": language = "lo"
        case "MM": language = "my"
        case "BD": language = "bn"
        case "IN": language = "hi"
        case "NP": language = "ne"
        case "PK": language = "ur"
        case "LK": language = "si"
        case "AF", "IR": language = "fa"
        case "IL": language = "he"
        case "TR": language = "tr"
        case "AZ": language = "az"
        case "AM": language = "hy"
        case "GE": language = "ka"
        case "KZ": language = "kk"
        case "KG": language = "ky"
        case "UZ": language = "uz"
        case "RU", "BY": language = "ru"
        case "UA": language = "uk"
        case "PL": language = "pl"
        case "CZ": language = "cs"
        case "SK": language = "sk"
        case "HU": language = "hu"
        case "RO", "MD": language = "ro"
        case "BG": language = "bg"
        case "RS", "ME": language = "sr"
        case "HR", "BA": language = "hr"
        case "SI": language = "sl"
        case "AL": language = "sq"
        case "MK": language = "mk"
        case "GR", "CY": language = "el"
        case "DE", "AT", "LI": language = "de"
        case "CH": language = "de"
        case "NL": language = "nl"
        case "BE": language = "nl"
        case "FR", "MC": language = "fr"
        case "LU": language = "fr"
        case "IT", "SM", "VA": language = "it"
        case "ES", "AR", "BO", "CL", "CO", "CR", "CU", "DO", "EC",
             "GQ", "GT", "HN", "MX", "NI", "PA", "PE", "PR", "PY",
             "SV", "UY", "VE": language = "es"
        case "PT", "BR", "AO", "CV", "GW", "MZ", "ST", "TL": language = "pt"
        case "DK": language = "da"
        case "NO": language = "nb"
        case "SE": language = "sv"
        case "FI": language = "fi"
        case "IS": language = "is"
        case "EE": language = "et"
        case "LV": language = "lv"
        case "LT": language = "lt"
        case "SA", "AE", "BH", "DZ", "EG", "IQ", "JO", "KW", "LB",
             "LY", "MA", "MR", "OM", "PS", "QA", "SD", "SO", "SY",
             "TN", "YE": language = "ar"
        case "ET": language = "am"
        case "KE", "TZ": language = "sw"
        case "ZA": language = "en"
        default: language = "en"
        }
        return "\(language)-\(countryCode)"
    }
}

enum BrowserNetworkTimeZonePolicy {
    static func identifier(forCountryCode rawCountryCode: String) -> String? {
        // A country code cannot choose a city in a multi-zone country.
        switch rawCountryCode.uppercased() {
        case "JP": return "Asia/Tokyo"
        case "KR": return "Asia/Seoul"
        case "CN": return "Asia/Shanghai"
        case "TW": return "Asia/Taipei"
        case "HK": return "Asia/Hong_Kong"
        case "MO": return "Asia/Macau"
        case "SG": return "Asia/Singapore"
        case "MY": return "Asia/Kuala_Lumpur"
        case "DE": return "Europe/Berlin"
        case "FR": return "Europe/Paris"
        case "GB": return "Europe/London"
        case "ZA": return "Africa/Johannesburg"
        default: return nil
        }
    }
}

enum BrowserOutwardRequestPolicy {
    static let preferenceDidChangeNotification = Notification.Name(
        "BrowserDoNotTrackPreferenceDidChange"
    )

    static func applying(
        to request: URLRequest,
        locale: String,
        doNotTrackEnabled: Bool
    ) -> URLRequest {
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return request
        }
        var result = request
        result.setValue(
            CefNativeSiteLanguagePolicy.languageOverride(for: request.url)
                ?? FingerprintPrivacyPolicy.acceptLanguageList(for: locale),
            forHTTPHeaderField: "Accept-Language"
        )
        if doNotTrackEnabled {
            result.setValue("1", forHTTPHeaderField: "DNT")
        } else {
            result.setValue(nil, forHTTPHeaderField: "DNT")
        }
        return result
    }

    static func current(_ request: URLRequest) -> URLRequest {
        applying(
            to: request,
            locale: FingerprintPrivacyPolicy.outwardLocale,
            doNotTrackEnabled: PhiPreferences.GeneralSettings.doNotTrack.loadValue()
        )
    }

    static func needsCurrentHeaders(_ request: URLRequest) -> Bool {
        guard let method = request.httpMethod?.uppercased(),
              method == "GET" || method == "HEAD" else {
            return false
        }
        let expected = current(request)
        return expected.value(forHTTPHeaderField: "Accept-Language")
                != request.value(forHTTPHeaderField: "Accept-Language")
            || expected.value(forHTTPHeaderField: "DNT")
                != request.value(forHTTPHeaderField: "DNT")
    }

    static func doNotTrackJavaScript(enabled: Bool) -> String {
        let value = enabled ? "'1'" : "null"
        return """
        (() => {
          const value = \(value);
          const replaceGetter = (target, name) => {
            if (!target) return;
            try {
              const descriptor = Object.getOwnPropertyDescriptor(target, name);
              const receiver = target === globalThis.Navigator?.prototype
                ? globalThis.navigator : globalThis;
              // CEF already applies the preference natively. Preserve matching getters.
              if (descriptor?.get && descriptor.get.call(receiver) === value) return;
              if (descriptor && descriptor.configurable !== true) return;
              Object.defineProperty(target, name, {
                get: () => value,
                configurable: true,
                enumerable: descriptor?.enumerable === true
              });
            } catch (_) {}
          };
          replaceGetter(globalThis.Navigator?.prototype, 'doNotTrack');
          replaceGetter(globalThis.Window?.prototype, 'doNotTrack');
        })();
        """
    }
}

enum MediaResourceDiscoveryPolicy {
    static let javaScript = #"""
    (() => {
      if (globalThis.__astraMediaResources) return;
      const resources = [];
      const seen = new Set();
      const record = entry => {
        if (!/\.(m3u8|mpd|mp4|m4v|mov|webm|mp3|m4a|aac|ogg|opus)(?:$|[?#])/i.test(entry.name)) return;
        try {
          const url = new URL(entry.name, location.href);
          if (!['http:', 'https:'].includes(url.protocol)) return;
          url.hash = '';
          if (seen.has(url.href)) return;
          seen.add(url.href);
          resources.push(url.href);
        } catch (_) {}
      };
      Object.defineProperty(globalThis, '__astraMediaResources', {value: resources});
      try {
        performance.getEntriesByType('resource').forEach(record);
        const observer = new PerformanceObserver(list => list.getEntries().forEach(record));
        observer.observe({type: 'resource', buffered: true});
      } catch (_) {}
    })();
    """#
}

enum CanvasSessionLanguagePolicy {
    private static let supportedHosts = [
        "elearning.fudan.edu.cn"
    ]

    static func applying(to url: URL, preferredLanguage: String) -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              supportedHosts.contains(host),
              !preferredLanguage.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "session_locale" }
        queryItems.append(URLQueryItem(name: "session_locale", value: preferredLanguage))
        components.queryItems = queryItems
        return components.url ?? url
    }
}

enum CefBrowserDataPage: String, CaseIterable {
    case history = "chrome://history"
    case clearBrowsingData = "chrome://settings/clearBrowserData"
}

enum AudioFingerprintPrivacyPolicy {
    static let javaScript = """
    (() => {
      if (globalThis.__astraUsesNativeSecurityChallengeSurfaces) {
        return;
      }
      if (globalThis.__astraAudioPrivacyInstalled) {
        return;
      }

      Object.defineProperty(globalThis, "__astraAudioPrivacyInstalled", {
        value: true,
        configurable: false,
        enumerable: false,
        writable: false
      });

      const randomWords = new Uint32Array(2);
      if (globalThis.crypto?.getRandomValues) {
        globalThis.crypto.getRandomValues(randomWords);
      } else {
        randomWords[0] = Math.floor(Math.random() * 0x100000000);
        randomWords[1] = Math.floor(Math.random() * 0x100000000);
      }
      const sessionFactor = 1 + ((randomWords[0] / 0xffffffff) - 0.5) * 0.00002;
      const byteDirection = (randomWords[1] & 1) === 0 ? -1 : 1;

      const replaceMethod = (prototype, name, implementation) => {
        if (!prototype || typeof prototype[name] !== "function") {
          return;
        }
        Object.defineProperty(prototype, name, {
          value: implementation(prototype[name]),
          configurable: true,
          enumerable: false,
          writable: true
        });
      };

      const farbleFloatValues = (values) => {
        if (!values || typeof values.length !== "number") {
          return;
        }
        for (let index = 0; index < values.length; index += 1) {
          const value = values[index];
          if (Number.isFinite(value) && value !== 0) {
            values[index] = value * sessionFactor;
          }
        }
      };

      const farbleByteValues = (values) => {
        if (!values || typeof values.length !== "number") {
          return;
        }
        const offset = randomWords[1] % 32;
        for (let index = offset; index < values.length; index += 32) {
          const value = values[index];
          values[index] = Math.max(0, Math.min(255, value + byteDirection));
        }
      };

      if (typeof AudioBuffer === "function") {
        const farbledChannels = new WeakMap();
        replaceMethod(AudioBuffer.prototype, "getChannelData", (nativeMethod) => function(channel) {
          const values = nativeMethod.call(this, channel);
          let channels = farbledChannels.get(this);
          if (!channels) {
            channels = new Set();
            farbledChannels.set(this, channels);
          }
          if (!channels.has(channel)) {
            farbleFloatValues(values);
            channels.add(channel);
          }
          return values;
        });
        replaceMethod(AudioBuffer.prototype, "copyFromChannel", (nativeMethod) => function(destination, ...args) {
          const result = nativeMethod.call(this, destination, ...args);
          farbleFloatValues(destination);
          return result;
        });
      }

      if (typeof AnalyserNode === "function") {
        for (const name of ["getFloatFrequencyData", "getFloatTimeDomainData"]) {
          replaceMethod(AnalyserNode.prototype, name, (nativeMethod) => function(values) {
            const result = nativeMethod.call(this, values);
            farbleFloatValues(values);
            return result;
          });
        }
        for (const name of ["getByteFrequencyData", "getByteTimeDomainData"]) {
          replaceMethod(AnalyserNode.prototype, name, (nativeMethod) => function(values) {
            const result = nativeMethod.call(this, values);
            farbleByteValues(values);
            return result;
          });
        }
      }

      if (typeof AudioNode === "function") {
        const nativeConnect = AudioNode.prototype.connect;
        const deferredConnections = [];
        const deferredConnectionKeys = new WeakMap();
        const upstreamSources = new WeakMap();
        const maximumDeferredConnections = 256;
        const activationBatchSize = 16;
        let deferredConnectionIndex = 0;
        let activationTaskScheduled = false;
        let audioOutputActivated = false;
        const hasUserActivation = () => globalThis.navigator?.userActivation?.hasBeenActive === true;
        const rememberConnection = (source, destination) => {
          if (!(destination instanceof AudioNode)) {
            return;
          }
          let sources = upstreamSources.get(destination);
          if (!sources) {
            sources = new Set();
            upstreamSources.set(destination, sources);
          }
          sources.add(source);
        };
        const hasSilentGainUpstream = (node, visited = new Set()) => {
          if (!node || visited.has(node)) {
            return false;
          }
          visited.add(node);
          if (typeof GainNode === "function" && node instanceof GainNode &&
              Number(node.gain?.value) === 0) {
            return true;
          }
          const sources = upstreamSources.get(node);
          if (!sources) {
            return false;
          }
          for (const source of sources) {
            if (hasSilentGainUpstream(source, visited)) {
              return true;
            }
          }
          return false;
        };
        const shouldDeferOutput = (source, destination) => {
          const context = source?.context;
          if (!context || destination !== context.destination || audioOutputActivated || hasUserActivation()) {
            return false;
          }
          return true;
        };
        const connectionKey = (args) => args.map((value) => `${typeof value}:${String(value)}`).join("|");
        const deferConnection = (source, destination, args) => {
          const key = connectionKey(args);
          let keys = deferredConnectionKeys.get(source);
          if (!keys) {
            keys = new Set();
            deferredConnectionKeys.set(source, keys);
          }
          if (keys.has(key) || deferredConnections.length >= maximumDeferredConnections) {
            return;
          }
          keys.add(key);
          deferredConnections.push({ source, destination, args, key });
        };

        Object.defineProperty(AudioNode.prototype, "connect", {
          value: function(destination, ...args) {
            rememberConnection(this, destination);
            const context = this?.context;
            if (context && destination === context.destination && hasSilentGainUpstream(this)) {
              return destination;
            }
            if (shouldDeferOutput(this, destination)) {
              deferConnection(this, destination, args);
              return destination;
            }
            return nativeConnect.call(this, destination, ...args);
          },
          configurable: true,
          enumerable: false,
          writable: true
        });

        const scheduleActivationTask = (callback) => {
          if (typeof globalThis.setTimeout === "function") {
            globalThis.setTimeout(callback, 0);
            return;
          }
          Promise.resolve().then(callback);
        };
        const drainDeferredConnections = () => {
          activationTaskScheduled = false;
          const batchEnd = Math.min(
            deferredConnectionIndex + activationBatchSize,
            deferredConnections.length
          );
          while (deferredConnectionIndex < batchEnd) {
            const connection = deferredConnections[deferredConnectionIndex];
            deferredConnectionIndex += 1;
            deferredConnectionKeys.get(connection.source)?.delete(connection.key);
            if (hasSilentGainUpstream(connection.source)) {
              continue;
            }
            try {
              nativeConnect.call(
                connection.source,
                connection.destination,
                ...connection.args
              );
            } catch (_) {
              // Ignore graphs that the page discarded before activation.
            }
          }
          if (deferredConnectionIndex < deferredConnections.length) {
            scheduleDeferredConnections();
            return;
          }
          deferredConnections.length = 0;
          deferredConnectionIndex = 0;
        };
        const scheduleDeferredConnections = () => {
          if (activationTaskScheduled || deferredConnectionIndex >= deferredConnections.length) {
            return;
          }
          activationTaskScheduled = true;
          scheduleActivationTask(drainDeferredConnections);
        };
        const activateAudioOutput = (event) => {
          if (!event || event.isTrusted !== true || audioOutputActivated) {
            return;
          }
          audioOutputActivated = true;
          for (const eventName of ["pointerdown", "keydown", "touchstart"]) {
            globalThis.removeEventListener?.(eventName, activateAudioOutput, true);
          }
          scheduleDeferredConnections();
        };
        for (const eventName of ["pointerdown", "keydown", "touchstart"]) {
          globalThis.addEventListener?.(eventName, activateAudioOutput, {
            capture: true,
            passive: true
          });
        }
      }
    })();
    """
}

enum FingerprintPrivacyPolicy {
    private static var configuredOutwardLocale: String?
    private static var configuredEgressCountryCode: String?
    private static let strictHostsKey = "privacy.strictFingerprintHosts"
    static let activeStrictHosts: Set<String> = {
        if CommandLine.arguments.contains("--cef-smoke-test"),
           CommandLine.arguments.contains("--astra-strict-test-disabled") { return [] }
        var hosts = savedStrictHosts()
        if CommandLine.arguments.contains("--cef-smoke-test"),
           let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--astra-strict-test-host=") }),
           let host = siteHost("https://" + String(argument.dropFirst("--astra-strict-test-host=".count))) {
            hosts.insert(host)
        }
        return hosts
    }()

    static func savedStrictHosts(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: strictHostsKey) ?? ["claude.ai"])
    }

    static func siteHost(_ rawURL: String) -> String? {
        guard let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func setStrictProtection(_ enabled: Bool, host: String, defaults: UserDefaults = .standard) {
        guard let normalized = siteHost("https://\(host)") else { return }
        var hosts = savedStrictHosts(defaults: defaults)
        if enabled { hosts.insert(normalized) } else { hosts.remove(normalized) }
        defaults.set(hosts.sorted(), forKey: strictHostsKey)
    }

    static func strictJavaScript(hosts: Set<String>) -> String {
        let hostJSON = String(data: try! JSONEncoder().encode(hosts.sorted()), encoding: .utf8)!
        return """
        (() => {
          if (globalThis.__astraUsesNativeSecurityChallengeSurfaces) return;
          const hosts = new Set(\(hostJSON));
          const matches = value => {
            try { return hosts.has(new URL(value).hostname.toLowerCase().replace(/\\.$/, '')); }
            catch (_) { return false; }
          };
          const origins = Array.from(location.ancestorOrigins || []);
          if (!matches(location.href) && !origins.some(matches)) return;
          const deny = () => { throw new DOMException('Blocked by strict site privacy.', 'SecurityError'); };
          const replace = (target, name, value) => {
            if (!target || !(name in target)) return;
            try { Object.defineProperty(target, name, {value, configurable: false, writable: false}); }
            catch (_) {}
          };
          for (const name of ['CanvasRenderingContext2D', 'OffscreenCanvasRenderingContext2D']) {
            replace(globalThis[name]?.prototype, 'getImageData', deny);
          }
          replace(globalThis.HTMLCanvasElement?.prototype, 'toDataURL', deny);
          replace(globalThis.HTMLCanvasElement?.prototype, 'toBlob', deny);
          replace(globalThis.OffscreenCanvas?.prototype, 'convertToBlob', () => Promise.reject(new DOMException('Blocked by strict site privacy.', 'SecurityError')));
          for (const name of ['WebGLRenderingContext', 'WebGL2RenderingContext']) {
            const proto = globalThis[name]?.prototype;
            if (!proto) continue;
            const parameter = proto.getParameter, extension = proto.getExtension;
            replace(proto, 'readPixels', deny);
            replace(proto, 'getParameter', function(value) {
              return value === 37445 || value === 37446 ? null : parameter.call(this, value);
            });
            replace(proto, 'getExtension', function(value) {
              return String(value).toLowerCase() === 'webgl_debug_renderer_info' ? null : extension.call(this, value);
            });
          }
          for (const name of ['OfflineAudioContext', 'webkitOfflineAudioContext']) {
            replace(globalThis[name]?.prototype, 'startRendering', () => Promise.reject(new DOMException('Blocked by strict site privacy.', 'SecurityError')));
          }
          replace(globalThis.AudioBuffer?.prototype, 'getChannelData', deny);
          replace(globalThis.AudioBuffer?.prototype, 'copyFromChannel', deny);
          for (const name of ['getFloatFrequencyData', 'getByteFrequencyData', 'getFloatTimeDomainData', 'getByteTimeDomainData']) {
            replace(globalThis.AnalyserNode?.prototype, name, deny);
          }
          replace(globalThis, 'queryLocalFonts', () => Promise.resolve([]));
          // A WebGPU adapter exposes GPU identity and limits without a permission prompt.
          // Returning null is the API's normal unavailable-adapter result.
          replace(globalThis.GPU?.prototype, 'requestAdapter', () => Promise.resolve(null));
        })();
        """
    }

    static var interfaceLocale: String {
        interfaceLocale(
            for: PhiPreferences.GeneralSettings.activeProcessAppLanguage()
        )
    }

    static var outwardLocale: String {
        configuredOutwardLocale ?? interfaceLocale
    }

    static func configureOutwardLocale(_ locale: String, countryCode: String? = nil) {
        configuredOutwardLocale = locale
        configuredEgressCountryCode = countryCode
    }

    static var acceptLanguageList: String {
        acceptLanguageList(for: outwardLocale)
    }

    static func interfaceLocale(for appLanguage: SupportedAppLanguage) -> String {
        switch appLanguage {
        case .english:
            return "en-US"
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        case .japanese:
            return "ja-JP"
        case .french:
            return "fr-FR"
        case .german:
            return "de-DE"
        case .dutch:
            return "nl-NL"
        case .spanish:
            return "es-ES"
        case .korean:
            return "ko-KR"
        }
    }

    static func acceptLanguageList(for locale: String) -> String {
        if locale == "en-US" {
            return BrowserNetworkLanguagePolicy.preferredLanguages(forCountryCode: configuredEgressCountryCode)
        }
        let primaryLanguage = locale.split(separator: "-").first.map(String.init) ?? locale
        var languages: [String] = []
        for language in [locale, primaryLanguage, "en-US", "en"]
        where !language.isEmpty && !languages.contains(language) {
            languages.append(language)
        }
        return languages.joined(separator: ",")
    }

    private static let processSeed = UUID().uuidString

    static var javaScript: String {
        siteScopedJavaScript(for: outwardLocale, hosts: activeStrictHosts)
    }

    static func siteScopedJavaScript(for locale: String, hosts: Set<String>) -> String {
        let hostsJSON = String(data: try! JSONEncoder().encode(hosts.sorted()), encoding: .utf8)!
        return """
        (() => {
          const hosts = new Set(\(hostsJSON));
          const host = String(location.hostname || '').toLowerCase().replace(/\\.$/, '');
          const parentSelected = Array.from(location.ancestorOrigins || []).some(origin => {
            try { return hosts.has(new URL(origin).hostname.toLowerCase().replace(/\\.$/, '')); }
            catch (_) { return false; }
          });
          if (!hosts.has(host) && !parentSelected) return;
          \(javaScript(for: locale))
        })();
        """
    }

    static func javaScript(for outwardLocale: String) -> String {
        let outwardLocaleValue = outwardLocale
        let outwardLanguages = FingerprintPrivacyPolicy.acceptLanguageList(for: outwardLocale)
        let surfacePolicy = #"""
        (() => {
          if (globalThis.__astraUsesNativeSecurityChallengeSurfaces) {
            return;
          }
          if (globalThis.__astraFingerprintPrivacyInstalled) {
            return;
          }

          Object.defineProperty(globalThis, "__astraFingerprintPrivacyInstalled", {
            value: true,
            configurable: false,
            enumerable: false,
            writable: false
          });

          const processSeed = "\#(processSeed)";
          const hashString = (value) => {
            let hash = 2166136261;
            for (let index = 0; index < value.length; index += 1) {
              hash ^= value.charCodeAt(index);
              hash = Math.imul(hash, 16777619);
            }
            return hash >>> 0;
          };
          const hostname = String(globalThis.location?.hostname || "opaque").toLowerCase();
          const siteSeed = hashString(`${processSeed}:${hostname}`);
          const byteDirection = (siteSeed & 1) === 0 ? -1 : 1;

          const replaceMethod = (prototype, name, implementation) => {
            if (!prototype || typeof prototype[name] !== "function") {
              return;
            }
            try {
              const nativeMethod = prototype[name];
              Object.defineProperty(prototype, name, {
                value: implementation(nativeMethod),
                configurable: true,
                enumerable: false,
                writable: true
              });
            } catch (_) {
              // Some engines expose non-configurable compatibility methods.
            }
          };

          const replaceGetter = (prototype, name, value) => {
            if (!prototype) {
              return;
            }
            try {
              const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
              const receiver = prototype === globalThis.Navigator?.prototype
                ? globalThis.navigator : globalThis.screen;
              const current = descriptor?.get?.call(receiver);
              const alreadyMatches = current === value ||
                (Array.isArray(current) && Array.isArray(value) &&
                 current.length === value.length && current.every((entry, index) => entry === value[index]));
              // Preserve native getters when their values already meet the policy.
              if (alreadyMatches) return;
              if (!descriptor || descriptor.configurable !== true) {
                return;
              }
              Object.defineProperty(prototype, name, {
                get: () => value,
                configurable: true,
                enumerable: descriptor.enumerable === true
              });
            } catch (_) {
              // Leave the native value when the engine does not allow wrapping.
            }
          };

          const farbleBytes = (values, salt = 0) => {
            if (!values || typeof values.length !== "number" || values.length < 4) {
              return;
            }
            const pixelCount = Math.floor(values.length / 4);
            const stride = Math.max(1, Math.floor(pixelCount / 8));
            let pixel = ((siteSeed ^ salt) >>> 0) % pixelCount;
            for (let count = 0; count < 8 && pixel < pixelCount; count += 1) {
              const channel = ((siteSeed >>> (count % 24)) + count) % 3;
              const index = pixel * 4 + channel;
              const value = Number(values[index]);
              if (Number.isFinite(value)) {
                values[index] = Math.max(0, Math.min(255, value + byteDirection));
              }
              pixel = (pixel + stride) % pixelCount;
            }
          };

          if (typeof CanvasRenderingContext2D === "function") {
            const prototype = CanvasRenderingContext2D.prototype;
            const nativeGetImageData = prototype.getImageData;
            const nativePutImageData = prototype.putImageData;
            const nativeDrawImage = prototype.drawImage;

            replaceMethod(prototype, "getImageData", (nativeMethod) => function(...args) {
              const imageData = nativeMethod.apply(this, args);
              farbleBytes(imageData?.data, 0x2d);
              return imageData;
            });

            if (typeof HTMLCanvasElement === "function") {
              const canvasPrototype = HTMLCanvasElement.prototype;
              const nativeToDataURL = canvasPrototype.toDataURL;
              const nativeToBlob = canvasPrototype.toBlob;
              const protectedCopy = (canvas) => {
                if (!canvas?.ownerDocument || canvas.width < 1 || canvas.height < 1) {
                  return canvas;
                }
                try {
                  const copy = canvas.ownerDocument.createElement("canvas");
                  copy.width = canvas.width;
                  copy.height = canvas.height;
                  const context = copy.getContext("2d");
                  nativeDrawImage.call(context, canvas, 0, 0);
                  const imageData = nativeGetImageData.call(
                    context,
                    0,
                    0,
                    copy.width,
                    copy.height
                  );
                  farbleBytes(imageData.data, copy.width ^ copy.height);
                  nativePutImageData.call(context, imageData, 0, 0);
                  return copy;
                } catch (_) {
                  return canvas;
                }
              };

              replaceMethod(canvasPrototype, "toDataURL", () => function(...args) {
                return nativeToDataURL.apply(protectedCopy(this), args);
              });
              replaceMethod(canvasPrototype, "toBlob", () => function(callback, ...args) {
                return nativeToBlob.call(protectedCopy(this), callback, ...args);
              });
            }
          }

          const protectWebGL = (constructor) => {
            if (typeof constructor !== "function") {
              return;
            }
            const prototype = constructor.prototype;
            replaceMethod(prototype, "getParameter", (nativeMethod) => function(parameter) {
              if (parameter === 0x9245) return "Google Inc. (Apple)";
              if (parameter === 0x9246) {
                return "ANGLE (Apple, ANGLE Metal Renderer: Apple GPU, Unspecified Version)";
              }
              const value = nativeMethod.call(this, parameter);
              const numericCaps = new Map([
                [0x0d33, 8192],
                [0x851c, 8192],
                [0x84e8, 8192],
                [0x8869, 16],
                [0x8872, 16],
                [0x8b4c, 16],
                [0x8b4d, 32]
              ]);
              const cap = numericCaps.get(parameter);
              return typeof value === "number" && cap ? Math.min(value, cap) : value;
            });
            replaceMethod(prototype, "readPixels", (nativeMethod) => function(...args) {
              const result = nativeMethod.apply(this, args);
              const output = args[6];
              if (ArrayBuffer.isView(output)) {
                farbleBytes(output, 0x3f);
              }
              return result;
            });
          };
          protectWebGL(globalThis.WebGLRenderingContext);
          protectWebGL(globalThis.WebGL2RenderingContext);

          const hiddenFonts = [
            "PingFang SC",
            "PingFang TC",
            "Hiragino Sans GB",
            "Hiragino Sans CNS",
            "STHeiti",
            "Heiti SC",
            "Heiti TC",
            "STSong",
            "Songti SC",
            "Songti TC",
            "STKaiti",
            "Kaiti SC",
            "Kaiti TC",
            "STFangsong",
            "Fangsong",
            "LiHei Pro",
            "LiSong Pro",
            "Microsoft YaHei",
            "Microsoft JhengHei",
            "SimHei",
            "SimSun",
            "NSimSun",
            "KaiTi",
            "FangSong",
            "Noto Sans CJK SC",
            "Noto Serif CJK SC",
            "Source Han Sans SC",
            "Source Han Serif SC"
          ].map((font) => font.toLowerCase());
          const containsHiddenFont = (value) => {
            const normalized = String(value || "").replace(/["']/g, "").toLowerCase();
            return hiddenFonts.some((font) => normalized.includes(font));
          };
          const genericFontDeclaration = (value, familyOnly) => {
            if (!containsHiddenFont(value)) {
              return value;
            }
            if (familyOnly) {
              return "monospace";
            }
            const match = String(value).match(
              /^(.*?\b(?:\d+(?:\.\d+)?(?:px|pt|pc|in|cm|mm|em|rem|ex|ch|vw|vh|vmin|vmax|%))(?:\s*\/\s*[^\s]+)?\s+).+$/i
            );
            return match ? `${match[1]}monospace` : value;
          };

          const replaceSanitizedSetter = (prototype, name, familyOnly) => {
            if (!prototype) {
              return;
            }
            try {
              let descriptorOwner = prototype;
              let descriptor = Object.getOwnPropertyDescriptor(descriptorOwner, name);
              while (!descriptor && descriptorOwner) {
                descriptorOwner = Object.getPrototypeOf(descriptorOwner);
                descriptor = descriptorOwner
                  ? Object.getOwnPropertyDescriptor(descriptorOwner, name)
                  : undefined;
              }
              if (!descriptor?.get || !descriptor?.set || descriptor.configurable !== true) {
                return;
              }
              Object.defineProperty(descriptorOwner, name, {
                get: descriptor.get,
                set(value) {
                  return descriptor.set.call(
                    this,
                    genericFontDeclaration(value, familyOnly)
                  );
                },
                configurable: true,
                enumerable: descriptor.enumerable === true
              });
            } catch (_) {
              // Font rendering remains available when a setter cannot be wrapped.
            }
          };
          replaceSanitizedSetter(globalThis.CanvasRenderingContext2D?.prototype, "font", false);

          const fontFaceSetPrototype = globalThis.FontFaceSet?.prototype
            || Object.getPrototypeOf(globalThis.document?.fonts || null);
          replaceMethod(fontFaceSetPrototype, "check", (nativeMethod) =>
            function(font, text) {
              if (containsHiddenFont(font)) {
                return false;
              }
              return nativeMethod.call(this, font, text);
            }
          );
          const cssStylePrototype = globalThis.CSSStyleDeclaration?.prototype;
          const nativeGetPropertyValue = cssStylePrototype?.getPropertyValue;
          const nativeGetPropertyPriority = cssStylePrototype?.getPropertyPriority;
          const nativeSetProperty = cssStylePrototype?.setProperty;
          const nativeRemoveProperty = cssStylePrototype?.removeProperty;
          const measureWithoutProtectedFont = (element, measurement) => {
            const style = element?.style;
            if (!style
                || typeof nativeGetPropertyValue !== "function"
                || typeof nativeSetProperty !== "function") {
              return measurement();
            }
            const declaration = nativeGetPropertyValue.call(style, "font-family");
            if (!containsHiddenFont(declaration)) {
              return measurement();
            }
            const priority = typeof nativeGetPropertyPriority === "function"
              ? nativeGetPropertyPriority.call(style, "font-family")
              : "";
            const genericFamilies = String(declaration).toLowerCase().match(
              /(?:^|[,\s])(monospace|sans-serif|serif|system-ui)(?=\s*(?:,|$))/g
            );
            const fallback = genericFamilies?.at(-1)?.trim().replace(/^,/, "").trim()
              || "monospace";
            try {
              nativeSetProperty.call(style, "font-family", fallback, priority);
            } catch (_) {
              return measurement();
            }
            try {
              return measurement();
            } finally {
              try {
                if (declaration) {
                  nativeSetProperty.call(style, "font-family", declaration, priority);
                } else if (typeof nativeRemoveProperty === "function") {
                  nativeRemoveProperty.call(style, "font-family");
                }
              } catch (_) {
                // Preserve native layout behavior if the inline style is immutable.
              }
            }
          };
          const replaceFontMetricGetter = (prototype, name) => {
            if (!prototype) {
              return;
            }
            try {
              let descriptorOwner = prototype;
              let descriptor = Object.getOwnPropertyDescriptor(descriptorOwner, name);
              while (!descriptor && descriptorOwner) {
                descriptorOwner = Object.getPrototypeOf(descriptorOwner);
                descriptor = descriptorOwner
                  ? Object.getOwnPropertyDescriptor(descriptorOwner, name)
                  : undefined;
              }
              if (!descriptor?.get || descriptor.configurable !== true) {
                return;
              }
              Object.defineProperty(descriptorOwner, name, {
                get() {
                  return measureWithoutProtectedFont(
                    this,
                    () => descriptor.get.call(this)
                  );
                },
                configurable: true,
                enumerable: descriptor.enumerable === true
              });
            } catch (_) {
              // Native metrics remain available when a getter cannot be wrapped.
            }
          };
          replaceFontMetricGetter(globalThis.HTMLElement?.prototype, "offsetWidth");
          replaceFontMetricGetter(globalThis.HTMLElement?.prototype, "offsetHeight");
          replaceMethod(globalThis.Element?.prototype, "getBoundingClientRect", (nativeMethod) =>
            function(...args) {
              return measureWithoutProtectedFont(
                this,
                () => nativeMethod.apply(this, args)
              );
            }
          );
          if (globalThis.navigator && typeof globalThis.navigator.queryLocalFonts === "function") {
            try {
              Object.defineProperty(globalThis.navigator, "queryLocalFonts", {
                value: async () => [],
                configurable: true,
                enumerable: false,
                writable: false
              });
            } catch (_) {
              // Native permission enforcement remains the fallback.
            }
          }

          // Battery state remains protected. Client Hints are reduced natively;
          // wrapping their Promise API adds detectable changes and breaks callers.
          const denyHighEntropyProbe = () => {
            throw new DOMException('Device fingerprint probe blocked.', 'NotAllowedError');
          };
          replaceMethod(globalThis.Navigator?.prototype, "getBattery", () => denyHighEntropyProbe);

          replaceGetter(globalThis.Navigator?.prototype, "hardwareConcurrency", 8);
          if ("deviceMemory" in (globalThis.Navigator?.prototype || {})) {
            replaceGetter(globalThis.Navigator.prototype, "deviceMemory", 8);
          }
          const mainlandDomains = "\#(CefNativeSiteLanguagePolicy.mainlandDomains.joined(separator: ","))".split(",");
          const host = location.hostname.toLowerCase().replace(/\.$/, "");
          const nativeChinese = mainlandDomains.some(domain => host === domain || host.endsWith("." + domain));
          const englishDomains = "\#(CefNativeSiteLanguagePolicy.englishDomains.joined(separator: ","))".split(",");
          const nativeEnglish = englishDomains.some(domain => host === domain || host.endsWith("." + domain));
          const siteLanguage = nativeEnglish ? "en-US" : nativeChinese ? "zh-CN" : "\#(outwardLocaleValue)";
          const siteLanguages = nativeEnglish ? ["en-US", "en"] : nativeChinese ? ["zh-CN", "zh", "en"] : "\#(outwardLanguages)".split(",");
          replaceGetter(globalThis.Navigator?.prototype, "language", siteLanguage);
          replaceGetter(
            globalThis.Navigator?.prototype,
            "languages",
            Object.freeze(siteLanguages)
          );
          replaceGetter(globalThis.Screen?.prototype, "colorDepth", 24);
          replaceGetter(globalThis.Screen?.prototype, "pixelDepth", 24);
        })();
        """#
        return CefSecurityChallengeCompatibilityPolicy.javaScript
            + "\n"
            + AudioFingerprintPrivacyPolicy.javaScript
            + "\n"
            + surfacePolicy
            + "\n"
            + strictJavaScript(hosts: activeStrictHosts)
    }
}

/// Reads Chrome-runtime extension metadata from the profile directory. CEF's
/// Chrome runtime owns installation and execution, while this catalog only
/// adapts its persisted manifests to Astra's existing native extension UI.
struct CefInstalledExtensionCatalog {
    private struct Record {
        let id: String
        let version: String
        let directory: URL
        let manifest: [String: Any]
    }

    let rootURL: URL
    var defaults: UserDefaults = .standard
    var fileManager: FileManager = .default

    func installedInfo(
        profileId: String,
        isDefaultProfile: Bool,
        isIncognito: Bool
    ) -> [[String: Any]] {
        guard !isIncognito else { return [] }
        let records = installedRecords(profileId: profileId, isDefaultProfile: isDefaultProfile)
        let pinned = pinnedExtensionIds(profileId: profileId)
        let pinnedIndex = Dictionary(uniqueKeysWithValues: pinned.enumerated().map { ($0.element, $0.offset) })

        return records.map { record in
            var info: [String: Any] = [
                "id": record.id,
                "name": localizedName(for: record),
                "version": record.version,
                "isPinned": pinnedIndex[record.id] != nil,
                "pinnedIndex": pinnedIndex[record.id] ?? -1,
                "isForcePinned": false,
            ]
            if let iconData = iconData(for: record) {
                info["icon"] = iconData.base64EncodedString()
            }
            return info
        }
    }

    func contains(
        extensionId: String,
        profileId: String,
        isDefaultProfile: Bool,
        isIncognito: Bool
    ) -> Bool {
        guard !isIncognito else { return false }
        return record(
            extensionId: extensionId,
            profileId: profileId,
            isDefaultProfile: isDefaultProfile
        ) != nil
    }

    func actionURL(
        extensionId: String,
        profileId: String,
        isDefaultProfile: Bool,
        isIncognito: Bool
    ) -> String? {
        guard !isIncognito,
              let record = record(
                extensionId: extensionId,
                profileId: profileId,
                isDefaultProfile: isDefaultProfile
              ) else { return nil }

        let action = (record.manifest["action"] as? [String: Any])
            ?? (record.manifest["browser_action"] as? [String: Any])
            ?? (record.manifest["page_action"] as? [String: Any])
        let popup = action?["default_popup"] as? String
        let optionsUI = (record.manifest["options_ui"] as? [String: Any])?["page"] as? String
        let optionsPage = record.manifest["options_page"] as? String
        guard let path = safeExtensionPagePath(popup ?? optionsUI ?? optionsPage) else {
            return "chrome://extensions/?id=\(extensionId)"
        }
        return "chrome-extension://\(extensionId)/\(path)"
    }

    func setPinned(
        _ isPinned: Bool,
        extensionId: String,
        profileId: String
    ) {
        var pinned = pinnedExtensionIds(profileId: profileId)
        pinned.removeAll(where: { $0 == extensionId })
        if isPinned {
            pinned.append(extensionId)
        }
        defaults.set(pinned, forKey: pinnedDefaultsKey(profileId: profileId))
    }

    func movePinned(
        extensionId: String,
        to destinationIndex: Int,
        profileId: String
    ) -> Bool {
        var pinned = pinnedExtensionIds(profileId: profileId)
        guard let sourceIndex = pinned.firstIndex(of: extensionId) else { return false }
        let item = pinned.remove(at: sourceIndex)
        pinned.insert(item, at: max(0, min(destinationIndex, pinned.count)))
        defaults.set(pinned, forKey: pinnedDefaultsKey(profileId: profileId))
        return true
    }

    private func installedRecords(profileId: String, isDefaultProfile: Bool) -> [Record] {
        let roots = extensionRoots(profileId: profileId, isDefaultProfile: isDefaultProfile)
        var byId: [String: Record] = [:]
        for root in roots {
            guard let identifiers = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for identifierDirectory in identifiers where isExtensionId(identifierDirectory.lastPathComponent) {
                guard let record = newestRecord(in: identifierDirectory) else { continue }
                if let existing = byId[record.id],
                   existing.version.compare(record.version, options: .numeric) != .orderedAscending {
                    continue
                }
                byId[record.id] = record
            }
        }
        return byId.values.sorted {
            localizedName(for: $0).localizedCaseInsensitiveCompare(localizedName(for: $1)) == .orderedAscending
        }
    }

    private func record(
        extensionId: String,
        profileId: String,
        isDefaultProfile: Bool
    ) -> Record? {
        guard isExtensionId(extensionId) else { return nil }
        return extensionRoots(profileId: profileId, isDefaultProfile: isDefaultProfile)
            .compactMap { newestRecord(in: $0.appendingPathComponent(extensionId, isDirectory: true)) }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    private func newestRecord(in identifierDirectory: URL) -> Record? {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: identifierDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let sortedVersions = versions.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
        for versionDirectory in sortedVersions {
            let manifestURL = versionDirectory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return Record(
                id: identifierDirectory.lastPathComponent,
                version: manifest["version"] as? String ?? versionDirectory.lastPathComponent,
                directory: versionDirectory,
                manifest: manifest
            )
        }
        return nil
    }

    private func extensionRoots(profileId: String, isDefaultProfile: Bool) -> [URL] {
        let profileRoot: URL
        if isDefaultProfile {
            profileRoot = rootURL
        } else {
            profileRoot = rootURL
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(Self.sanitizedProfileName(profileId), isDirectory: true)
        }
        // Chrome's global profile uses Default/Extensions. Request-context
        // profiles have used both layouts across CEF releases, so accept both.
        return [
            profileRoot.appendingPathComponent("Default/Extensions", isDirectory: true),
            profileRoot.appendingPathComponent("Extensions", isDirectory: true),
        ]
    }

    private func localizedName(for record: Record) -> String {
        let rawName = record.manifest["name"] as? String ?? record.id
        guard rawName.hasPrefix("__MSG_"), rawName.hasSuffix("__"),
              let locale = record.manifest["default_locale"] as? String else {
            return rawName
        }
        let start = rawName.index(rawName.startIndex, offsetBy: 6)
        let end = rawName.index(rawName.endIndex, offsetBy: -2)
        let key = String(rawName[start..<end])
        let messagesURL = record.directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: messagesURL),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = messages[key] as? [String: Any],
              let message = entry["message"] as? String,
              !message.isEmpty else {
            return rawName
        }
        return message
    }

    private func iconData(for record: Record) -> Data? {
        let action = (record.manifest["action"] as? [String: Any])
            ?? (record.manifest["browser_action"] as? [String: Any])
            ?? (record.manifest["page_action"] as? [String: Any])
        let iconValue = action?["default_icon"] ?? record.manifest["icons"]
        guard let path = iconPath(from: iconValue),
              let relativePath = safeExtensionPagePath(path) else { return nil }
        return try? Data(contentsOf: record.directory.appendingPathComponent(relativePath))
    }

    private func iconPath(from value: Any?) -> String? {
        if let path = value as? String { return path }
        guard let paths = value as? [String: Any] else { return nil }
        return paths
            .compactMap { key, value -> (Int, String)? in
                guard let size = Int(key), let path = value as? String else { return nil }
                return (size, path)
            }
            .max(by: { $0.0 < $1.0 })?
            .1
    }

    private func safeExtensionPagePath(_ rawPath: String?) -> String? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let path = rawPath.drop(while: { $0 == "/" })
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !components.contains(".."),
              !rawPath.contains("\\") else { return nil }
        return String(path)
    }

    private func pinnedExtensionIds(profileId: String) -> [String] {
        defaults.stringArray(forKey: pinnedDefaultsKey(profileId: profileId)) ?? []
    }

    private func pinnedDefaultsKey(profileId: String) -> String {
        "CefPinnedExtensions.\(profileId)"
    }

    private func isExtensionId(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("a"..."p").contains(String($0)) }
    }

    static func sanitizedProfileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let trimmed = cleaned.drop(while: { $0 == "." })
        return trimmed.isEmpty ? "Profile" : String(trimmed)
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
        const targetDocuments = (() => {
          const documents = [];
          const queue = [document];
          const seen = new Set();
          while (queue.length > 0 && documents.length < 32) {
            const candidate = queue.shift();
            if (!candidate || seen.has(candidate)) continue;
            seen.add(candidate);
            documents.push(candidate);
            for (const frame of candidate.querySelectorAll('iframe,frame')) {
              try {
                if (frame.contentDocument) queue.push(frame.contentDocument);
              } catch (_) {}
            }
          }
          return documents;
        })();
        const targetQueryAll = (selector) => {
          const matches = [];
          for (const candidateDocument of targetDocuments) {
            matches.push(...candidateDocument.querySelectorAll(selector));
          }
          return matches;
        };
        const targetRectInTopViewport = (candidate) => {
          const rect = candidate.getBoundingClientRect();
          let left = rect.left;
          let top = rect.top;
          let ownerWindow = candidate.ownerDocument?.defaultView;
          while (ownerWindow && ownerWindow !== window) {
            let frameElement;
            try {
              frameElement = ownerWindow.frameElement;
            } catch (_) {
              return null;
            }
            if (!frameElement) return null;
            const frameRect = frameElement.getBoundingClientRect();
            left += frameRect.left;
            top += frameRect.top;
            ownerWindow = frameElement.ownerDocument?.defaultView;
          }
          return { left, top, width: rect.width, height: rect.height };
        };
        let targetError = null;
        let element = null;
        if (targetRef) {
          element = targetQueryAll('[data-astra-ai-ref]').find(
            (candidate) => candidate.getAttribute('data-astra-ai-ref') === targetRef
          ) || null;
        }
        if (!element && targetSelector) {
          try {
            element = targetQueryAll(targetSelector)[targetMatchIndex] || null;
          } catch (_) {
            targetError = 'The CSS selector is invalid.';
          }
        }
        if (!element && Number.isInteger(targetIndex)) {
          element = targetQueryAll(`[data-astra-ai-index="${targetIndex}"]`)[0] || null;
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

enum UnmanagedChromiumWindowPolicy {
    /// Marks a `CefChromeBrowser` overlay so the unmanaged-window observer
    /// will not treat it as a Chrome-runtime popup. Newly created YouTube
    /// (and other heavy) pages become key before CEF has registered the
    /// browser; capturing that overlay force-closes the tab's engine and
    /// leaves a blank page that cannot be closed.
    static func markAsOwnedOverlay(_ window: NSWindow) {
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }

    static func shouldCapture(_ window: NSWindow) -> Bool {
        guard window.parent == nil else { return false }
        if window is CefBrowserWindow { return false }
        if window.isExcludedFromWindowsMenu,
           window.collectionBehavior.contains(.fullScreenAuxiliary) {
            return false
        }
        return true
    }

    static func routeURL(from urls: [URL]) -> URL? {
        urls.reversed().first { url in
            let absoluteString = url.absoluteString.lowercased()
            return absoluteString != "about:blank"
                && absoluteString != "chrome://newtab"
                && absoluteString != "chrome://newtab/"
        }
    }
}

enum CefWebContentClosePolicy {
    static func shouldCreateEngine(didRequestClose: Bool) -> Bool {
        !didRequestClose
    }

    /// `chromeBrowser.close()` can miss `onWindowDestroyed` when the overlay
    /// was already torn down underneath the wrapper. The tab strip still has
    /// to drop the tab on the user's close click.
    static let shouldFinishTabCloseWithoutWaitingForWindowDestruction = true
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
    private var extensionCatalogRootURL: URL?
    private var pendingPageContext: [String: PendingPageContext] = [:]
    private var pageContextTimeouts: [String: DispatchWorkItem] = [:]
    private var pendingAutomation: [String: PendingAutomation] = [:]
    private var automationTimeouts: [String: DispatchWorkItem] = [:]
    private var credentialHandlers: [String: WeakCredentialHandler] = [:]
    private var unmanagedBrowserWindowObserver: NSObjectProtocol?

    @objc static func bootstrapApplication() -> Bool {
        do {
            var configuration = CefConfiguration.default
            // Pair the native pump with runNativeMessageLoop(), never with
            // CefSwift's periodic external-pump driver.
            configuration.externalMessagePump = false
            let interfaceLocale = FingerprintPrivacyPolicy.interfaceLocale
            let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let overrideCountryCode = CommandLine.arguments
                .first(where: { $0.hasPrefix("--astra-egress-country=") })
                .map { String($0.dropFirst("--astra-egress-country=".count)) }
            let proxyEndpoint = BrowserProxyPolicy.effectiveLocalEndpoint()
            let egressLocation = isRunningTests || overrideCountryCode != nil
                ? nil : APIClient.resolvePublicIPv4Location(
                    proxyEndpoint: proxyEndpoint,
                    allowProxyFailover: false
                )
            let egressCountryCode = overrideCountryCode ?? egressLocation?.countryCode
            let outwardLocale: String
            if isRunningTests {
                outwardLocale = interfaceLocale
            } else {
                // VPN geography must not silently change the user's web language.
                // Set the native preference too: Chromium can regenerate navigation headers.
                outwardLocale = "en-US"
            }
            if !isRunningTests,
               let egressCountryCode,
               let browserTimeZone = BrowserNetworkTimeZonePolicy.identifier(
                   forCountryCode: egressCountryCode
               ) {
                setenv("TZ", browserTimeZone, 1)
                NSTimeZone.resetSystemTimeZone()
                AppLogInfo("[CEF] Browser egress time zone=\(browserTimeZone)")
            } else if !isRunningTests {
                // A proxy lookup timeout previously silently exposed the host time zone.
                AppLogWarn("[CEF] Egress time zone unresolved; retaining system time zone")
            }
            FingerprintPrivacyPolicy.configureOutwardLocale(outwardLocale, countryCode: egressCountryCode)
            AppLogInfo(
                "[CEF] Browser language fingerprint locale=\(outwardLocale); " +
                "interface locale=\(interfaceLocale)"
            )
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
            // Chromium's locale also controls Intl defaults in pages and workers.
            // Keep it aligned with native language negotiation, not AppKit UI language.
            configuration.locale = outwardLocale
            configuration.acceptLanguageList = FingerprintPrivacyPolicy.acceptLanguageList
            configuration.userAgentProduct = SupportedBrowserUserAgent.chromiumProduct
            // Let Chromium keep request, page and worker platform identity consistent.
            // Keep HTTPS on the same TCP route as CONNECT proxies. UDP/QUIC
            // can take a different VPN path and produce inconsistent site access.
            configuration.extraCommandLineSwitches.updateValue(nil, forKey: "disable-quic")
            let doNotTrackEnabled = PhiPreferences.GeneralSettings.doNotTrack.loadValue()
            configuration.documentStartJavaScript = [
                FingerprintPrivacyPolicy.javaScript,
                MediaResourceDiscoveryPolicy.javaScript,
                BrowserOutwardRequestPolicy.doNotTrackJavaScript(enabled: doNotTrackEnabled)
            ].joined(separator: "\n")
            configuration.doNotTrackEnabled = doNotTrackEnabled
            configuration.customSchemes.append(AstraMemorySchemeHandler.customScheme)
            if let endpoint = proxyEndpoint {
                configuration.extraCommandLineSwitches["proxy-server"] =
                    BrowserProxyPolicy.cefProxyServer(for: endpoint)
            }
            CefBrowserAccountPrivacyPolicy.apply(to: &configuration)
            try CefBrowserAccountPrivacyPolicy.prepareProfile(at: root)
            let secureDNSEnabled = UserDefaults.standard.object(forKey: BrowserSecureDNSPolicy.enabledKey) as? Bool ?? true
            try BrowserSecureDNSPolicy.prepareLocalState(at: root, enabled: secureDNSEnabled)
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
            CefRuntime.shared.registerSchemeHandler(
                scheme: AstraMemorySchemeHandler.schemeName,
                domain: AstraMemorySchemeHandler.domain,
                handler: AstraMemorySchemeHandler {
                    await MainActor.run {
                        AccountController.shared.localDataAccount?.userDataStorage
                            ?? Account.defaultAccount.userDataStorage
                    }
                }
            )
            shared.extensionCatalogRootURL = root
            shared.registerPageContextBridge()
            shared.registerAutomationBridge()
            shared.registerWebCredentialBridge()
            shared.startObservingUnmanagedBrowserWindows()

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

    @objc static func runApplication() {
        CefRuntime.shared.runNativeMessageLoop()
    }

    func applicationDidFinishLaunching() {
        if CommandLine.arguments.contains("--cef-time-zone-smoke") || CommandLine.arguments.contains("--cef-linux-identity-smoke") {
            // Run after restored tabs settle so this probe targets a neutral site.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.openExternalURLs([URL(string: "https://example.com")!])
            }
        }
        guard MainBrowserWindowControllersManager.shared.activeWindowController == nil else { return }
        let initialURL = CommandLine.arguments
            .first(where: { $0.hasPrefix("--astra-initial-url=") })?
            .dropFirst("--astra-initial-url=".count)
        openBrowserWindow(initialURL: initialURL.map(String.init) ?? "chrome://newtab")
    }

    /// Opens URLs delivered by Launch Services in the embedded Chromium
    /// runtime. The legacy framework bridge is absent in CEF builds, so these
    /// URLs must enter the same BrowserState path used by in-app new tabs.
    @MainActor
    func openExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        if let controller = MainBrowserWindowControllersManager.shared.activeWindowController {
            for url in urls {
                controller.browserState.createTab(
                    url.absoluteString,
                    focusAfterCreate: true
                )
            }
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openBrowserWindow(initialURL: urls[0].absoluteString)
        guard urls.count > 1,
              let controller = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        for url in urls.dropFirst() {
            controller.browserState.createTab(
                url.absoluteString,
                focusAfterCreate: true
            )
        }
    }

    /// Opens profile-scoped Chromium data pages inside the active Astra
    /// BrowserState. Routing through BrowserState is required in CEF builds:
    /// the legacy framework bridge is absent, and a Chromium command dispatched
    /// through it cannot select the active CEF request context.
    func openBrowserDataPage(_ page: CefBrowserDataPage) {
        if let controller = MainBrowserWindowControllersManager.shared.activeWindowController,
           !controller.browserState.isIncognito {
            controller.browserState.createTab(page.rawValue, focusAfterCreate: true)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openBrowserWindow(initialURL: page.rawValue)
    }

    @discardableResult
    func applyDoNotTrackPreference(_ enabled: Bool) -> Bool {
        let globalApplied = CefRuntime.shared.setDoNotTrackEnabled(enabled)
        let isolatedProfilesApplied = profiles.values.reduce(true) { result, profile in
            profile.setDoNotTrackEnabled(enabled) && result
        }
        NotificationCenter.default.post(
            name: BrowserOutwardRequestPolicy.preferenceDidChangeNotification,
            object: nil,
            userInfo: ["enabled": enabled]
        )
        return globalApplied && isolatedProfilesApplied
    }

    /// Chrome runtime extension APIs may create a complete native Chromium
    /// window without invoking the page popup delegate. Detect those windows,
    /// close their unregistered CEF browsers, and preserve meaningful content
    /// by reopening it as a normal Astra tab.
    private func startObservingUnmanagedBrowserWindows() {
        guard unmanagedBrowserWindowObserver == nil else { return }
        unmanagedBrowserWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.integrateUnmanagedBrowserWindow(window, attemptsRemaining: 3)
                }
            }
        }
    }

    private func integrateUnmanagedBrowserWindow(
        _ window: NSWindow,
        attemptsRemaining: Int
    ) {
        guard UnmanagedChromiumWindowPolicy.shouldCapture(window),
              MainBrowserWindowControllersManager.shared.findControllerWith(window: window) == nil else {
            return
        }

        guard let capture = CefRuntime.shared.closeUnmanagedBrowserWindow(window) else {
            guard attemptsRemaining > 1, window.isVisible else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
                guard let self, let window else { return }
                self.integrateUnmanagedBrowserWindow(
                    window,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        window.orderOut(nil)
        let routeURL = UnmanagedChromiumWindowPolicy.routeURL(from: capture.urls)
        AppLogInfo(
            "[CEF] Integrated unmanaged Chromium window browsers=" +
            "\(capture.browserIdentifiers) route=\(routeURL?.absoluteString ?? "none")"
        )
        guard let routeURL else { return }

        if let controller = MainBrowserWindowControllersManager.shared.activeWindowController {
            controller.browserState.createTab(routeURL.absoluteString, focusAfterCreate: true)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openBrowserWindow(initialURL: routeURL.absoluteString)
        }
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
    ) -> Tab {
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
            guard state.focusingTab?.guid != tab.guid else { return }
            state.focuseTab(tab)
        }
        // Selection changes before the asynchronous AppKit content swap. A
        // still-visible outgoing child window must not reclaim tab selection.
        wrapper.canReceiveFocus = { [weak state, weak tab] in
            guard let state, let tab else { return false }
            guard let selected = state.focusingTab else { return false }
            if selected.guid == tab.guid { return true }
            // Both panes in the selected split remain interactive.
            guard let split = state.splitGroup(forTabId: selected.guid) else { return false }
            return state.splitGroup(forTabId: tab.guid) == split
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
        wrapper.onSelectionAction = { [weak state, weak tab] action, selection in
            guard let state, let tab else { return }
            state.handleWebSelectionAction(action, text: selection, in: tab)
        }

        state.handleNewTabFromChromium(tab)
        if focusAfterCreate {
            state.focuseTab(tab)
        }
        return tab
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

    func installedExtensionInfo(profileId: String, isIncognito: Bool) -> [[String: Any]] {
        guard let extensionCatalogRootURL else { return [] }
        return CefInstalledExtensionCatalog(rootURL: extensionCatalogRootURL).installedInfo(
            profileId: profileId,
            isDefaultProfile: profileId == LocalStore.defaultProfileId,
            isIncognito: isIncognito
        )
    }

    func containsInstalledExtension(
        extensionId: String,
        profileId: String,
        isIncognito: Bool
    ) -> Bool {
        guard let extensionCatalogRootURL else { return false }
        return CefInstalledExtensionCatalog(rootURL: extensionCatalogRootURL).contains(
            extensionId: extensionId,
            profileId: profileId,
            isDefaultProfile: profileId == LocalStore.defaultProfileId,
            isIncognito: isIncognito
        )
    }

    func installedExtensionActionURL(
        extensionId: String,
        profileId: String,
        isIncognito: Bool
    ) -> String? {
        guard let extensionCatalogRootURL else { return nil }
        return CefInstalledExtensionCatalog(rootURL: extensionCatalogRootURL).actionURL(
            extensionId: extensionId,
            profileId: profileId,
            isDefaultProfile: profileId == LocalStore.defaultProfileId,
            isIncognito: isIncognito
        )
    }

    func setInstalledExtensionPinned(
        _ isPinned: Bool,
        extensionId: String,
        profileId: String
    ) {
        guard let extensionCatalogRootURL else { return }
        CefInstalledExtensionCatalog(rootURL: extensionCatalogRootURL).setPinned(
            isPinned,
            extensionId: extensionId,
            profileId: profileId
        )
    }

    func moveInstalledExtension(
        extensionId: String,
        to destinationIndex: Int,
        profileId: String
    ) -> Bool {
        guard let extensionCatalogRootURL else { return false }
        return CefInstalledExtensionCatalog(rootURL: extensionCatalogRootURL).movePinned(
            extensionId: extensionId,
            to: destinationIndex,
            profileId: profileId
        )
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
          const payload = {
            requestID: '\(requestID)',
            token: '\(token)',
            result: result.slice(0, 400000)
          };
          if (window.cefSwift && window.cefSwift.invoke) {
            await window.cefSwift.invoke('astraBrowserAutomation', payload);
          } else {
            await fetch('cefswift://bridge/astraBrowserAutomation', {
              method: 'POST',
              body: JSON.stringify(payload)
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
