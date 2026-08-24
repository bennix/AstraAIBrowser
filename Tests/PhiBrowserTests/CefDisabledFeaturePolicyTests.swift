// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import JavaScriptCore
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

final class AudioFingerprintPrivacyPolicyTests: XCTestCase {
    func testPolicyCoversAudioReadbackAndSilentDestinationConnections() {
        let script = AudioFingerprintPrivacyPolicy.javaScript

        XCTAssertTrue(script.contains("AudioBuffer"))
        XCTAssertTrue(script.contains("getChannelData"))
        XCTAssertTrue(script.contains("copyFromChannel"))
        XCTAssertTrue(script.contains("AnalyserNode"))
        XCTAssertTrue(script.contains("AudioNode"))
        XCTAssertTrue(script.contains("GainNode"))
        XCTAssertTrue(script.contains("userActivation"))
        XCTAssertTrue(script.contains("event.isTrusted"))
        XCTAssertFalse(script.contains("HTMLMediaElement"))
    }

    func testPolicyKeepsSilentOutputDisconnectedAfterTrustedInput() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.webAudioTestEnvironment)
        context.evaluateScript(AudioFingerprintPrivacyPolicy.javaScript)

        XCTAssertEqual(context.evaluateScript("testConnect(false)")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("testTrustedActivation()")?.toInt32(), 0)
        XCTAssertNil(exception?.toString())
    }

    func testPolicyPreservesUserActivatedAudioAndFarblesReadback() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.webAudioTestEnvironment)
        context.evaluateScript(AudioFingerprintPrivacyPolicy.javaScript)

        XCTAssertEqual(context.evaluateScript("testConnect(true, 1)")?.toInt32(), 1)
        XCTAssertEqual(
            context.evaluateScript("new AudioBuffer().getChannelData(0)[0] === 1")?.toBool(),
            false
        )
        XCTAssertNil(exception?.toString())
    }

    func testPolicyBlocksSilentGainThroughProcessingChain() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.webAudioTestEnvironment)
        context.evaluateScript(AudioFingerprintPrivacyPolicy.javaScript)

        XCTAssertEqual(context.evaluateScript("testSilentProcessingChain()")?.toInt32(), 2)
        XCTAssertNil(exception?.toString())
    }

    private static let webAudioTestEnvironment = """
    globalThis.window = globalThis;
    globalThis.location = { protocol: 'https:' };
    globalThis.navigator = { userActivation: { hasBeenActive: false } };
    globalThis.testListeners = {};
    globalThis.addEventListener = (name, callback) => { testListeners[name] = callback; };
    globalThis.document = { addEventListener: globalThis.addEventListener };
    globalThis.crypto = { getRandomValues(values) { values[0] = 123456789; return values; } };
    globalThis.nativeConnectCount = 0;

    class AudioNode {
      connect(destination) { nativeConnectCount += 1; return destination; }
    }
    class GainNode extends AudioNode {
      constructor(context, value) { super(); this.context = context; this.gain = { value }; }
    }
    class AnalyserNode extends AudioNode {
      getFloatFrequencyData(values) { values.fill(1); }
      getFloatTimeDomainData(values) { values.fill(1); }
      getByteFrequencyData(values) { values.fill(128); }
      getByteTimeDomainData(values) { values.fill(128); }
    }
    class ScriptProcessorNode extends AudioNode {}
    class AudioBuffer {
      constructor() { this.values = new Float32Array([1, 1]); }
      getChannelData() { return this.values; }
      copyFromChannel(destination) { destination.set(this.values); }
    }
    class AudioContext {
      constructor() { this.destination = { context: this }; }
    }
    globalThis.AudioNode = AudioNode;
    globalThis.GainNode = GainNode;
    globalThis.AnalyserNode = AnalyserNode;
    globalThis.ScriptProcessorNode = ScriptProcessorNode;
    globalThis.AudioBuffer = AudioBuffer;
    globalThis.AudioContext = AudioContext;
    globalThis.testConnect = (activated, gainValue = 0) => {
      nativeConnectCount = 0;
      navigator.userActivation.hasBeenActive = activated;
      const context = new AudioContext();
      const gain = new GainNode(context, gainValue);
      gain.connect(context.destination);
      return nativeConnectCount;
    };
    globalThis.testTrustedActivation = () => {
      testListeners.pointerdown({ isTrusted: true });
      return nativeConnectCount;
    };
    globalThis.testSilentProcessingChain = () => {
      nativeConnectCount = 0;
      navigator.userActivation.hasBeenActive = true;
      const context = new AudioContext();
      const gain = new GainNode(context, 0);
      const analyser = new AnalyserNode();
      analyser.context = context;
      const processor = new ScriptProcessorNode();
      processor.context = context;
      gain.connect(analyser);
      analyser.connect(processor);
      processor.connect(context.destination);
      return nativeConnectCount;
    };
    """
}
