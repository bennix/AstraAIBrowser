// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class DefaultBrowserViewModelTests: XCTestCase {
    func testDefaultBrowserRequiresBothWebSchemes() {
        let bundleIdentifier = "com.example.Astra"

        XCTAssertTrue(DefaultBrowserViewModel.isDefaultBrowser(
            applicationBundleIdentifier: bundleIdentifier,
            handlerBundleIdentifiers: [bundleIdentifier, bundleIdentifier]
        ))
        XCTAssertFalse(DefaultBrowserViewModel.isDefaultBrowser(
            applicationBundleIdentifier: bundleIdentifier,
            handlerBundleIdentifiers: [bundleIdentifier, "com.example.Other"]
        ))
        XCTAssertFalse(DefaultBrowserViewModel.isDefaultBrowser(
            applicationBundleIdentifier: bundleIdentifier,
            handlerBundleIdentifiers: [bundleIdentifier]
        ))
    }

    func testAppDeclaresViewerRoleForWebURLSchemes() throws {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                as? [[String: Any]]
        )
        let webType = try XCTUnwrap(urlTypes.first { type in
            let schemes = type["CFBundleURLSchemes"] as? [String]
            return schemes?.contains("http") == true
                && schemes?.contains("https") == true
        })

        XCTAssertEqual(webType["CFBundleTypeRole"] as? String, "Viewer")
    }

}
