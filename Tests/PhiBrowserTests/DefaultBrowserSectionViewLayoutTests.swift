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

}
