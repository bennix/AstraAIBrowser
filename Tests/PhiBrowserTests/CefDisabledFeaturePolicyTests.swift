// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class CefDisabledFeaturePolicyTests: XCTestCase {
    func testMergingPreservesCEFCompatibilityFeatures() {
        let result = CefDisabledFeaturePolicy.mergingCEFDefaults(
            "AutofillActorMode,GlicActorUi,LensOverlay"
        )

        XCTAssertEqual(
            result,
            "AutofillActorMode,GlicActorUi,LensOverlay,UserAgentClientHint"
        )
    }

    func testMergingDoesNotDuplicateAppRequiredFeature() {
        let result = CefDisabledFeaturePolicy.mergingCEFDefaults(
            "GlicActorUi, UserAgentClientHint,GlicActorUi"
        )

        XCTAssertEqual(result, "GlicActorUi,UserAgentClientHint")
    }

    func testMergingSupportsMissingCEFDefaults() {
        XCTAssertEqual(
            CefDisabledFeaturePolicy.mergingCEFDefaults(nil),
            "UserAgentClientHint"
        )
    }
}

final class CefWebRTCPrivacyPolicyTests: XCTestCase {
    func testPolicyDisablesNonProxiedUDP() {
        XCTAssertEqual(
            CefWebRTCPrivacyPolicy.commandLineSwitch,
            "webrtc-ip-handling-policy"
        )
        XCTAssertEqual(
            CefWebRTCPrivacyPolicy.forceCommandLineSwitch,
            "force-webrtc-ip-handling-policy"
        )
        XCTAssertEqual(
            CefWebRTCPrivacyPolicy.requiredValue,
            "disable_non_proxied_udp"
        )
    }
}
