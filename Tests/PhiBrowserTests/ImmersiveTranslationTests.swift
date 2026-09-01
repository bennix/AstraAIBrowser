// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ImmersiveTranslationTests: XCTestCase {
    func testBatchPlannerEmitsCompletedTranslationSizedSteps() {
        let segments = (0..<19).map {
            ImmersiveTranslationSegment(id: "segment-\($0)", text: "Text \($0)")
        }

        let batches = ImmersiveTranslationBatchPlanner.batches(for: segments)

        XCTAssertEqual(batches.map(\.count), [8, 8, 3])
        XCTAssertEqual(batches.flatMap { $0 }, segments)
    }

    func testBatchPlannerHonorsCharacterLimitWithoutDroppingSegments() {
        let segments = [
            ImmersiveTranslationSegment(id: "one", text: "12345"),
            ImmersiveTranslationSegment(id: "two", text: "67890"),
            ImmersiveTranslationSegment(id: "three", text: "abc"),
        ]

        let batches = ImmersiveTranslationBatchPlanner.batches(
            for: segments,
            maximumSegmentCount: 8,
            maximumCharacterCount: 9
        )

        XCTAssertEqual(batches.map { $0.map(\.id) }, [["one"], ["two", "three"]])
        XCTAssertEqual(batches.flatMap { $0 }, segments)
    }

    func testSelectionNormalizationOnlyTrimsOuterWhitespace() {
        XCTAssertEqual(
            SelectionTranslationPolicy.normalizedText("  First line\nSecond line  "),
            "First line\nSecond line"
        )
    }
}
