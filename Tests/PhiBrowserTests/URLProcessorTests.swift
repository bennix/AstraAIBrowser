// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class URLProcessorTests: XCTestCase {
    func testLegacyBrowserMemoryURLsUseLocalAIMemoryPage() {
        for input in [
            "chrome://memory",
            "chrome://memory/memory.html",
            "phi://memory/memory.html?view=recent",
        ] {
            XCTAssertEqual(
                URLProcessor.processUserInput(input),
                URLProcessor.browserMemoryURL
            )
        }
        XCTAssertEqual(
            URLProcessor.processUserInput("astra://memory/"),
            URLProcessor.browserMemoryURL
        )
        XCTAssertEqual(
            URLProcessor.processUserInput("astra://settings"),
            "chrome://settings"
        )
        XCTAssertEqual(
            URLProcessor.phiBrandEnsuredUrlString("chrome://settings"),
            "astra://settings"
        )
        XCTAssertEqual(
            URLProcessor.phiBrandEnsuredUrlString("phi://downloads"),
            "astra://downloads"
        )
        XCTAssertEqual(
            URLProcessor.phiBrandEnsuredUrlString("https://example.com"),
            "https://example.com"
        )
    }

    func testBrowserMemoryCompatibilityDoesNotRewriteSimilarHosts() {
        XCTAssertEqual(
            URLProcessor.processUserInput("chrome://memory-internals/"),
            "chrome://memory-internals/"
        )
        XCTAssertEqual(
            URLProcessor.processUserInput("https://memory/memory.html"),
            "https://memory/memory.html"
        )
    }

    func testExplicitGoogleSearchDoesNotInterpretDomainAsNavigation() {
        let result = URLProcessor.googleSearchURL(for: "google.com")

        XCTAssertEqual(result, "https://www.google.com/search?q=google.com")
    }

    func testExplicitGoogleSearchPercentEncodesMultilingualQuery() throws {
        let result = URLProcessor.googleSearchURL(for: "浏览器 AI")
        let components = try XCTUnwrap(URLComponents(string: result))

        XCTAssertEqual(components.queryItems?.first?.name, "q")
        XCTAssertEqual(components.queryItems?.first?.value, "浏览器 AI")
    }

    func testExternalApplicationSchemeIsPreservedForLaunchServices() {
        let input = "wemeet://auth/sso?sso_auth_code=redacted"

        XCTAssertTrue(URLProcessor.isURL(input))
        XCTAssertEqual(URLProcessor.processUserInput(input), input)
        XCTAssertTrue(ExternalApplicationURLPolicy.shouldOpenExternally(URL(string: input)!))
    }

    func testBrowserOwnedAndExecutableSchemesAreNotExternalApplications() {
        for rawURL in [
            "https://example.com",
            "http://example.com",
            "file:///tmp/example",
            "javascript:alert(1)",
            "data:text/plain,hello",
            "chrome://settings",
            "chrome-search://local-ntp/local-ntp.html",
            "astra://memory/",
        ] {
            XCTAssertFalse(
                ExternalApplicationURLPolicy.shouldOpenExternally(URL(string: rawURL)!),
                "Browser-owned scheme must not be handed to Launch Services: \(rawURL)"
            )
        }
    }

    func testOriginNavigationComparisonTreatsWWWAndRootSlashAsEquivalent() {
        XCTAssertTrue(
            URLProcessor.areEquivalentForOriginNavigation(
                "https://google.com",
                "https://www.google.com/"
            )
        )
    }

    func testOriginNavigationComparisonPreservesMeaningfulURLDifferences() {
        let cases = [
            ("http://example.com/path?q=a", "https://example.com/path?q=a", "scheme"),
            ("https://example.com/Path?q=a", "https://example.com/path?q=a", "path case"),
            ("https://example.com/path?q=A", "https://example.com/path?q=a", "query case"),
            ("https://example.com/path", "https://example.com/path/", "non-root slash")
        ]

        for (lhs, rhs, difference) in cases {
            XCTAssertFalse(
                URLProcessor.areEquivalentForOriginNavigation(lhs, rhs),
                "Origin navigation must preserve the \(difference) difference"
            )
        }
    }
}
