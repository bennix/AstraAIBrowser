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

final class FingerprintPrivacyPolicyTests: XCTestCase {
    func testPolicyCoversHighEntropyBrowserSurfaces() {
        let script = FingerprintPrivacyPolicy.javaScript

        XCTAssertTrue(script.contains("__astraFingerprintPrivacyInstalled"))
        XCTAssertTrue(script.contains("CanvasRenderingContext2D"))
        XCTAssertTrue(script.contains("HTMLCanvasElement"))
        XCTAssertTrue(script.contains("WebGLRenderingContext"))
        XCTAssertTrue(script.contains("readPixels"))
        XCTAssertTrue(script.contains("queryLocalFonts"))
        XCTAssertTrue(script.contains("PingFang SC"))
        XCTAssertTrue(script.contains("Hiragino Sans GB"))
        XCTAssertTrue(script.contains("offsetWidth"))
        XCTAssertTrue(script.contains("getBoundingClientRect"))
        XCTAssertTrue(script.contains("hardwareConcurrency"))
        XCTAssertTrue(script.contains("colorDepth"))
        XCTAssertTrue(script.contains("AudioBuffer"))
    }

    func testPolicyHidesChineseFontsAndNormalizesHardwareSignals() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.browserSurfaceTestEnvironment)
        context.evaluateScript(FingerprintPrivacyPolicy.javaScript)

        XCTAssertEqual(context.evaluateScript("navigator.hardwareConcurrency")?.toInt32(), 8)
        XCTAssertEqual(context.evaluateScript("navigator.deviceMemory")?.toInt32(), 8)
        XCTAssertEqual(context.evaluateScript("screen.colorDepth")?.toInt32(), 24)
        XCTAssertEqual(context.evaluateScript("screen.pixelDepth")?.toInt32(), 24)
        let expectedLocale = FingerprintPrivacyPolicy.outwardLocale
        XCTAssertEqual(context.evaluateScript("navigator.language")?.toString(), expectedLocale)
        XCTAssertEqual(
            context.evaluateScript("navigator.languages.join(',')")?.toString(),
            FingerprintPrivacyPolicy.acceptLanguageList(for: expectedLocale)
        )
        XCTAssertEqual(
            context.evaluateScript("new FontFaceSet().check('16px \\\"PingFang SC\\\"')")?.toBool(),
            false
        )
        XCTAssertEqual(
            context.evaluateScript("testSanitizedFontFamily()")?.toString(),
            "monospace"
        )
        XCTAssertNil(exception?.toString())
    }

    func testPolicyFarblesCanvasAndMasksWebGLRenderer() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.browserSurfaceTestEnvironment)
        context.evaluateScript(FingerprintPrivacyPolicy.javaScript)

        XCTAssertEqual(context.evaluateScript("testCanvasWasFarbled()")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("testWebGLWasFarbled()")?.toBool(), true)
        XCTAssertEqual(
            context.evaluateScript("testWebGLRenderer()")?.toString(),
            "ANGLE (Apple, ANGLE Metal Renderer: Apple GPU, Unspecified Version)"
        )
        XCTAssertNil(exception?.toString())
    }

    func testPolicyHidesFontsWhenFontFaceSetConstructorIsNotGlobal() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.browserSurfaceTestEnvironment)
        context.evaluateScript("""
        globalThis.document = { fonts: new FontFaceSet() };
        delete globalThis.FontFaceSet;
        """)
        context.evaluateScript(FingerprintPrivacyPolicy.javaScript)

        XCTAssertEqual(
            context.evaluateScript("document.fonts.check('16px \\\"PingFang SC\\\"')")?.toBool(),
            false
        )
        XCTAssertNil(exception?.toString())
    }

    func testPolicyNeutralizesDOMFontMetricProbes() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript(Self.browserSurfaceTestEnvironment)
        context.evaluateScript("""
        class Element {
          getBoundingClientRect() { return { width: this.offsetWidth, height: 20 }; }
        }
        class HTMLElement extends Element {
          constructor() { super(); this.style = new CSSStyleDeclaration(); }
        }
        Object.defineProperty(HTMLElement.prototype, 'offsetWidth', {
          get() { return this.style.fontFamily.includes('PingFang') ? 200 : 100; },
          configurable: true,
          enumerable: true
        });
        Object.defineProperty(HTMLElement.prototype, 'offsetHeight', {
          get() { return 20; }, configurable: true, enumerable: true
        });
        globalThis.Element = Element;
        globalThis.HTMLElement = HTMLElement;
        """)
        context.evaluateScript(FingerprintPrivacyPolicy.javaScript)
        context.evaluateScript("""
        globalThis.metricProbe = new HTMLElement();
        Object.defineProperty(metricProbe.style, 'fontFamily', {
          value: 'PingFang SC, monospace', writable: true, configurable: true
        });
        """)

        XCTAssertEqual(context.evaluateScript("metricProbe.offsetWidth")?.toInt32(), 100)
        XCTAssertEqual(context.evaluateScript("metricProbe.style.fontFamily")?.toString(), "monospace")
        XCTAssertNil(exception?.toString())
    }

    func testPolicyUsesLocaleConsistentWithSimplifiedChineseAppLanguage() {
        let locale = FingerprintPrivacyPolicy.outwardLocale(for: .simplifiedChinese)
        XCTAssertEqual(locale, "zh-CN")
        XCTAssertEqual(
            FingerprintPrivacyPolicy.acceptLanguageList(for: locale),
            "zh-CN,zh,en-US,en"
        )
    }

    func testPolicyUsesLocaleConsistentWithTraditionalChineseAppLanguage() {
        XCTAssertEqual(
            FingerprintPrivacyPolicy.outwardLocale(for: .traditionalChinese),
            "zh-TW"
        )
    }

    func testPolicyUsesLocaleConsistentWithJapaneseAppLanguage() {
        XCTAssertEqual(
            FingerprintPrivacyPolicy.outwardLocale(for: .japanese),
            "ja-JP"
        )
    }

    private static let browserSurfaceTestEnvironment = """
    globalThis.window = globalThis;
    globalThis.location = { hostname: 'fingerprint.example' };
    globalThis.crypto = { getRandomValues(values) { values[0] = 1234; values[1] = 5678; return values; } };
    globalThis.addEventListener = () => {};

    class Navigator {}
    Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', {
      get() { return 10; }, configurable: true, enumerable: true
    });
    Object.defineProperty(Navigator.prototype, 'deviceMemory', {
      get() { return 32; }, configurable: true, enumerable: true
    });
    Object.defineProperty(Navigator.prototype, 'language', {
      get() { return 'en-US'; }, configurable: true, enumerable: true
    });
    Object.defineProperty(Navigator.prototype, 'languages', {
      get() { return ['en-US']; }, configurable: true, enumerable: true
    });
    Navigator.prototype.queryLocalFonts = async () => [{ family: 'PingFang SC' }];
    globalThis.Navigator = Navigator;
    globalThis.navigator = new Navigator();

    class Screen {}
    Object.defineProperty(Screen.prototype, 'colorDepth', {
      get() { return 30; }, configurable: true, enumerable: true
    });
    Object.defineProperty(Screen.prototype, 'pixelDepth', {
      get() { return 30; }, configurable: true, enumerable: true
    });
    globalThis.Screen = Screen;
    globalThis.screen = new Screen();

    class CanvasRenderingContext2D {
      constructor() { this.fontValue = '10px sans-serif'; }
      getImageData() { return { data: new Uint8ClampedArray(64).fill(100) }; }
      putImageData() {}
      drawImage() {}
    }
    Object.defineProperty(CanvasRenderingContext2D.prototype, 'font', {
      get() { return this.fontValue; },
      set(value) { this.fontValue = value; },
      configurable: true,
      enumerable: true
    });
    globalThis.CanvasRenderingContext2D = CanvasRenderingContext2D;

    class HTMLCanvasElement {
      constructor() {
        this.width = 4;
        this.height = 4;
        this.ownerDocument = { createElement: () => new HTMLCanvasElement() };
        this.context = new CanvasRenderingContext2D();
      }
      getContext() { return this.context; }
      toDataURL() { return 'native'; }
      toBlob(callback) { callback('native'); }
    }
    globalThis.HTMLCanvasElement = HTMLCanvasElement;

    class CSSStyleProperties {
      constructor() { this.fontValue = ''; this.fontFamilyValue = ''; }
    }
    class CSSStyleDeclaration extends CSSStyleProperties {
      setProperty(name, value) { this[name] = value; }
    }
    Object.defineProperty(CSSStyleProperties.prototype, 'font', {
      get() { return this.fontValue; },
      set(value) { this.fontValue = value; },
      configurable: true,
      enumerable: true
    });
    Object.defineProperty(CSSStyleProperties.prototype, 'fontFamily', {
      get() { return this.fontFamilyValue; },
      set(value) { this.fontFamilyValue = value; },
      configurable: true,
      enumerable: true
    });
    globalThis.CSSStyleDeclaration = CSSStyleDeclaration;

    class FontFaceSet { check() { return true; } }
    globalThis.FontFaceSet = FontFaceSet;

    class WebGLRenderingContext {
      getParameter() { return 'Apple M4'; }
      readPixels(x, y, width, height, format, type, output) { output.fill(100); }
    }
    globalThis.WebGLRenderingContext = WebGLRenderingContext;

    globalThis.testSanitizedFontFamily = () => {
      const style = new CSSStyleDeclaration();
      style.fontFamily = 'PingFang SC, sans-serif';
      return style.fontFamily;
    };
    globalThis.testCanvasWasFarbled = () => {
      const values = new CanvasRenderingContext2D().getImageData().data;
      return Array.from(values).some((value) => value !== 100);
    };
    globalThis.testWebGLWasFarbled = () => {
      const values = new Uint8Array(64);
      new WebGLRenderingContext().readPixels(0, 0, 4, 4, 0, 0, values);
      return Array.from(values).some((value) => value !== 100);
    };
    globalThis.testWebGLRenderer = () =>
      new WebGLRenderingContext().getParameter(0x9246);
    """
}
