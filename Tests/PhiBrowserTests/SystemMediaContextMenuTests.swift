// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import WebKit
import XCTest
@testable import Phi

final class SystemMediaContextMenuTests: XCTestCase {
    private final class MenuTarget: NSObject {
        @objc func perform(_ sender: Any?) {}
    }

    private final class NavigationObserver: NSObject, WKNavigationDelegate {
        let didFinish: XCTestExpectation

        init(didFinish: XCTestExpectation) {
            self.didFinish = didFinish
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinish.fulfill()
        }
    }

    @MainActor
    func testSearchWebMenuItemRoutesThroughSystemMediaWebView() {
        let webView = SystemMediaWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let menu = NSMenu()
        let searchItem = NSMenuItem(title: "Search", action: nil, keyEquivalent: "")
        searchItem.identifier = SystemMediaWebView.searchWebMenuItemIdentifier
        menu.addItem(searchItem)
        webView.onTranslateSelectedText = { _ in }

        webView.routeSearchWebMenuItems(in: menu)

        XCTAssertTrue(searchItem.target === webView)
        XCTAssertEqual(
            searchItem.action.map(NSStringFromSelector),
            "searchSelectedTextInNewTab:"
        )
        let translateItem = menu.items.first {
            $0.identifier == SystemMediaWebView.translateSelectionMenuItemIdentifier
        }
        XCTAssertTrue(translateItem?.target === webView)
        XCTAssertEqual(
            translateItem?.action.map(NSStringFromSelector),
            "translateSelectedText:"
        )
        XCTAssertEqual(
            menu.items.firstIndex {
                $0.identifier == SystemMediaWebView.translateSelectionMenuItemIdentifier
            },
            0
        )
    }

    @MainActor
    func testUnrelatedContextMenuItemsKeepTheirOriginalRouting() {
        let webView = SystemMediaWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let originalTarget = MenuTarget()
        let originalAction = #selector(MenuTarget.perform(_:))
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: "Copy",
            action: originalAction,
            keyEquivalent: ""
        )
        copyItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
        copyItem.target = originalTarget
        menu.addItem(copyItem)

        webView.routeSearchWebMenuItems(in: menu)

        XCTAssertTrue(copyItem.target === originalTarget)
        XCTAssertEqual(copyItem.action, originalAction)
    }

    @MainActor
    func testSearchActionReadsTheCurrentDocumentSelection() {
        let didLoad = expectation(description: "The test page loaded")
        let didSelectText = expectation(description: "The page selected text")
        let didRouteSearch = expectation(description: "The selected text was routed")
        let observer = NavigationObserver(didFinish: didLoad)
        let webView = SystemMediaWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: WKWebViewConfiguration()
        )
        webView.navigationDelegate = observer

        var routedQuery: String?
        webView.onSearchSelectedText = { query in
            routedQuery = query
            didRouteSearch.fulfill()
        }
        webView.loadHTMLString(
            "<p id='selection'>Anker Prime 160W</p>",
            baseURL: nil
        )
        wait(for: [didLoad], timeout: 5)

        webView.evaluateJavaScript(
            """
            const range = document.createRange();
            range.selectNodeContents(document.getElementById('selection'));
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            """
        ) { _, error in
            XCTAssertNil(error)
            didSelectText.fulfill()
        }
        wait(for: [didSelectText], timeout: 5)

        webView.searchSelectedTextInNewTab(NSMenuItem())

        wait(for: [didRouteSearch], timeout: 5)
        XCTAssertEqual(routedQuery, "Anker Prime 160W")
    }

    @MainActor
    func testTranslateActionReadsTheCurrentDocumentSelection() {
        let didLoad = expectation(description: "The test page loaded")
        let didSelectText = expectation(description: "The page selected text")
        let didRouteTranslation = expectation(description: "The selected text was routed")
        let observer = NavigationObserver(didFinish: didLoad)
        let webView = SystemMediaWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: WKWebViewConfiguration()
        )
        webView.navigationDelegate = observer

        var routedSelection: String?
        webView.onTranslateSelectedText = { selection in
            routedSelection = selection
            didRouteTranslation.fulfill()
        }
        webView.loadHTMLString(
            "<p id='selection'>Translate this passage now.</p>",
            baseURL: nil
        )
        wait(for: [didLoad], timeout: 5)

        webView.evaluateJavaScript(
            """
            const range = document.createRange();
            range.selectNodeContents(document.getElementById('selection'));
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            """
        ) { _, error in
            XCTAssertNil(error)
            didSelectText.fulfill()
        }
        wait(for: [didSelectText], timeout: 5)

        webView.translateSelectedText(NSMenuItem())

        wait(for: [didRouteTranslation], timeout: 5)
        XCTAssertEqual(routedSelection, "Translate this passage now.")
    }
}
