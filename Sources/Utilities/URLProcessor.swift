// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Converts user-entered text into a browser URL string.
public struct URLProcessor {

    /// Chromium removed the legacy `chrome://memory/memory.html` WebUI.
    /// Preserve the public route while moving its ownership to Astra's local,
    /// account-scoped AI memory page.
    public static let browserMemoryURL = "astra://memory/"
    
    /// Converts user input into a valid URL string.
    public static func processUserInput(_ searchText: String) -> String {
        let trimmedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isLegacyBrowserMemoryURL(trimmedText) {
            return browserMemoryURL
        }
        
        if trimmedText.hasPrefix("http://") || trimmedText.hasPrefix("https://") {
            return trimmedText
        } else if trimmedText.hasPrefix("astra://") {
            return trimmedText.replacingOccurrences(of: "astra://", with: "chrome://")
        } else if trimmedText.hasPrefix("chrome://") || trimmedText.hasPrefix("about://") {
            return trimmedText
        } else if trimmedText.hasPrefix("phi://") {
            return trimmedText.replacingOccurrences(of: "phi://", with: "chrome://")
        } else if let url = URL(string: trimmedText),
                  ExternalApplicationURLPolicy.shouldOpenExternally(url) {
            return trimmedText
        } else if isURL(trimmedText) {
            return "https://\(trimmedText)"
        } else {
            return "https://www.google.com/search?q=\(trimmedText)"
        }
    }

    /// Builds an explicit Google search URL without applying URL detection.
    /// Used when the user selects Google mode in the new-tab unified input.
    public static func googleSearchURL(for query: String) -> String {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url?.absoluteString ?? "https://www.google.com/search"
    }

    /// Compares URLs for bookmark and pinned-tab origin navigation.
    /// HTTP(S) `www.` variants and an optional root slash are equivalent;
    /// scheme, port, non-root path, query, and fragment differences remain significant.
    static func areEquivalentForOriginNavigation(_ lhs: String, _ rhs: String) -> Bool {
        guard let normalizedLHS = normalizedForOriginNavigation(lhs),
              let normalizedRHS = normalizedForOriginNavigation(rhs) else {
            return lhs == rhs
        }

        return normalizedLHS == normalizedRHS
    }
    
    /// Returns whether the text looks like a URL.
    public static func isURL(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedText.hasPrefix("http://") || 
           trimmedText.hasPrefix("https://") ||
           trimmedText.hasPrefix("chrome://") ||
           trimmedText.hasPrefix("about://") ||
           trimmedText.hasPrefix("astra://") ||
           trimmedText.hasPrefix("phi://") {
            return true
        }

        if let url = URL(string: trimmedText),
           ExternalApplicationURLPolicy.shouldOpenExternally(url) {
            return true
        }
        
        let domainPattern = #"^[^\s]+\.[^\s]+$"#
        let regex = try? NSRegularExpression(pattern: domainPattern)
        let range = NSRange(location: 0, length: trimmedText.utf16.count)
        return regex?.firstMatch(in: trimmedText, range: range) != nil
    }
    
    /// Extracts a display-friendly hostname from a URL.
    public static func displayName(for urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        
        if urlString.hasPrefix("chrome-extension:") {
            return ""
        }
        
        let displayHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return displayHost
    }
    
    static func phiBrandEnsuredUrlString(_ string: String) -> String {
        if string.hasPrefix("chrome://") {
            return "astra://" + string.dropFirst("chrome://".count)
        }
        if string.hasPrefix("phi://") {
            return "astra://" + string.dropFirst("phi://".count)
        }
        return string
    }

    static func isLegacyBrowserMemoryURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "chrome" || scheme == "phi" || scheme == "astra" else {
            return false
        }
        return components.host?.lowercased() == "memory"
    }

    private static func normalizedForOriginNavigation(_ rawURL: String) -> String? {
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        components.scheme = scheme
        if let host = components.host?.lowercased() {
            let stripsWWW = (scheme == "http" || scheme == "https") &&
                host.hasPrefix("www.") && host.count > 4
            components.host = stripsWWW ? String(host.dropFirst(4)) : host
        }
        if components.path == "/" {
            components.path = ""
        }

        return components.string
    }
}

/// Separates URLs owned by the browser from links that macOS applications own.
/// External links are still subject to user confirmation before Launch Services
/// receives them.
enum ExternalApplicationURLPolicy {
    private static let browserOwnedSchemes: Set<String> = [
        "about",
        "astra",
        "blob",
        "chrome",
        "chrome-extension",
        "data",
        "devtools",
        "file",
        "filesystem",
        "ftp",
        "http",
        "https",
        "javascript",
        "phi",
        "view-source",
        "ws",
        "wss",
    ]

    static func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else { return false }
        return !browserOwnedSchemes.contains(scheme) && !scheme.hasPrefix("chrome-")
    }
}
