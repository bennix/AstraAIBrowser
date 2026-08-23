// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ApplicationActivationWindowPolicyTests: XCTestCase {
    func testFrontsAnOrderedOutActiveWindowAfterApplicationActivation() {
        XCTAssertTrue(shouldFront(isVisible: false))
    }

    func testDoesNotRestoreAWindowTheUserMiniaturized() {
        XCTAssertFalse(shouldFront(isVisible: false, isMiniaturized: true))
    }

    func testSettledVisibleWindowDoesNotStealFocus() {
        XCTAssertFalse(shouldFront(isVisible: true))
    }

    func testFrontsAfterHidingASurfacedSiblingWindow() {
        XCTAssertTrue(shouldFront(isVisible: true, hidSiblingCount: 1))
    }

    func testFrontsToCorrectTheSelectedNativeTab() {
        XCTAssertTrue(shouldFront(isVisible: true, tabSelectionNeedsCorrection: true))
    }

    private func shouldFront(
        isVisible: Bool,
        isMiniaturized: Bool = false,
        hidSiblingCount: Int = 0,
        tabSelectionNeedsCorrection: Bool = false
    ) -> Bool {
        SpaceWindowSlot.shouldFrontActiveWindowDuringVisibilityReconcile(
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            hidSiblingCount: hidSiblingCount,
            tabSelectionNeedsCorrection: tabSelectionNeedsCorrection
        )
    }
}
