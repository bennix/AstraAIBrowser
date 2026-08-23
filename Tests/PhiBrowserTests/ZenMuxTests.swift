// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import CefKit
import Security
import XCTest
@testable import Phi

final class ZenMuxTests: XCTestCase {
    func testZenMuxBuildDoesNotRequireLegacyAuthentication() {
        XCTAssertFalse(PhiBuildCapabilities.supportsAuthentication)
        XCTAssertTrue(PhiBuildCapabilities.supportsAI)
    }

    func testSupportedModelsMatchProviderConfiguration() {
        XCTAssertEqual(
            ZenMuxModel.allCases.map(\.rawValue),
            [
                "google/gemini-3.7-flash",
                "x-ai/grok-4.6",
                "z-ai/glm-5.3",
            ]
        )
    }

    func testVisualBrowserControlUsesMultimodalModelOnly() {
        XCTAssertTrue(ZenMuxModel.geminiFlash.supportsVisualBrowserControl)
        XCTAssertFalse(ZenMuxModel.grok.supportsVisualBrowserControl)
        XCTAssertFalse(ZenMuxModel.glm.supportsVisualBrowserControl)
    }

    func testEncryptedCredentialRoundTripsWithoutPlaintextInJSON() throws {
        let keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let payload = ZenMuxCredentialStore.Payload(
            apiKey: "zenmux-secret-test-key",
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        let envelope = try ZenMuxCredentialStore.encrypt(
            payload: payload,
            keyData: keyData
        )
        let encodedEnvelope = try JSONEncoder().encode(envelope)

        XCTAssertFalse(String(decoding: encodedEnvelope, as: UTF8.self).contains(payload.apiKey))
        XCTAssertEqual(
            try ZenMuxCredentialStore.decrypt(envelope: envelope, keyData: keyData),
            payload
        )
    }

    func testEncryptedCredentialRejectsDifferentKey() throws {
        let originalKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let otherKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let envelope = try ZenMuxCredentialStore.encrypt(
            payload: .init(apiKey: "zenmux-secret-test-key", updatedAt: Date()),
            keyData: originalKey
        )

        XCTAssertThrowsError(
            try ZenMuxCredentialStore.decrypt(envelope: envelope, keyData: otherKey)
        )
    }

    func testCredentialStorePersistsAndReloadsEncryptedAPIKey() throws {
        let bundleIdentifier = "com.phibrowser.tests.\(UUID().uuidString)"
        let service = "\(bundleIdentifier).zenmux-credential"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("zenmux-credential.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        let store = ZenMuxCredentialStore(
            fileURL: fileURL,
            bundleIdentifier: bundleIdentifier
        )
        let apiKey = "zenmux-persistence-test-key"

        try store.saveAPIKey(apiKey)

        XCTAssertEqual(try store.loadAPIKey(), apiKey)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains(apiKey))
    }

    func testUnknownPreferenceValuesUseSafeDefaults() {
        let suiteName = "ZenMuxTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unknown-model", forKey: PhiPreferences.AISettings.zenMuxModelKey)
        defaults.set("unknown-input", forKey: PhiPreferences.AISettings.zenMuxInputLanguageKey)
        defaults.set("unknown-response", forKey: PhiPreferences.AISettings.zenMuxResponseLanguageKey)

        XCTAssertEqual(PhiPreferences.AISettings.loadZenMuxModel(from: defaults), .geminiFlash)
        XCTAssertEqual(PhiPreferences.AISettings.loadZenMuxInputLanguage(from: defaults), .automatic)
        XCTAssertEqual(PhiPreferences.AISettings.loadZenMuxResponseLanguage(from: defaults), .matchInput)
    }

    func testYouTubeVideoURLDetectionExcludesNonVideoPages() {
        XCTAssertTrue(APIClient.isYouTubeVideoURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(APIClient.isYouTubeVideoURL("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertTrue(APIClient.isYouTubeVideoURL("https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        XCTAssertEqual(
            APIClient.youtubeVideoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share"),
            "dQw4w9WgXcQ"
        )
        XCTAssertFalse(APIClient.isYouTubeVideoURL("https://www.youtube.com/"))
        XCTAssertFalse(APIClient.isYouTubeVideoURL("https://www.youtube.com/shorts/invalid"))
        XCTAssertFalse(APIClient.isYouTubeVideoURL("https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertFalse(APIClient.isYouTubeVideoURL(nil))
    }

    func testYouTubeWithoutTranscriptCannotBePresentedAsKnownVideoContent() throws {
        let instruction = try XCTUnwrap(ZenMuxChatSession.youtubeEvidenceInstruction(
            pageURL: "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            transcriptAvailable: false
        ))

        XCTAssertTrue(instruction.contains("No verified captions or transcript"))
        XCTAssertTrue(instruction.contains("Do not infer or invent video content"))
        XCTAssertNil(ZenMuxChatSession.youtubeEvidenceInstruction(
            pageURL: "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            transcriptAvailable: true
        ))
    }

    func testFailedYouTubeTranscriptCanRetryAfterCooldown() {
        let failure = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ZenMuxChatSession.shouldRetryYouTubeTranscript(
            lastFailure: failure,
            now: Date(timeIntervalSince1970: 1_059)
        ))
        XCTAssertTrue(ZenMuxChatSession.shouldRetryYouTubeTranscript(
            lastFailure: failure,
            now: Date(timeIntervalSince1970: 1_060)
        ))
    }

    func testTranscriptLanguagePreferenceStartsWithExplicitInputLanguage() {
        XCTAssertEqual(
            ZenMuxInputLanguage.traditionalChinese.transcriptLanguagePreferences.first,
            "zh-Hant"
        )
        XCTAssertTrue(
            ZenMuxInputLanguage.traditionalChinese.transcriptLanguagePreferences.contains("en")
        )
    }

    func testToolCallMessagesUseOpenAICompatibleFieldNames() throws {
        let call = ZenMuxToolCall(
            id: "call-1",
            type: "function",
            function: .init(name: "inspect_page", arguments: "{}")
        )
        let message = ZenMuxChatRequestMessage(
            role: "assistant",
            content: nil,
            toolCalls: [call]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        XCTAssertNotNil(object["tool_calls"])
        XCTAssertNil(object["toolCalls"])
    }

    func testToolResultMessagesUseToolCallIdentifier() throws {
        let message = ZenMuxChatRequestMessage(
            role: "tool",
            content: "Browser tool succeeded",
            toolCallID: "call-1"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        XCTAssertEqual(object["tool_call_id"] as? String, "call-1")
        XCTAssertNil(object["toolCallID"])
    }

    func testVisualInspectionUsesVertexInlineDataWithoutTemporaryFileURI() throws {
        let dataURL = "data:image/jpeg;base64,ZmFrZQ=="
        let data = try APIClient.makeZenMuxVisualLocalizationRequest(
            targetDescription: "Click the settings button",
            imageDataURL: dataURL
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue((parts[0]["text"] as? String)?.contains("settings button") == true)
        let inlineData = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inlineData["data"] as? String, "ZmFrZQ==")
        XCTAssertNil(parts[1]["fileData"])
    }

    func testVisualLocalizationRejectsOutOfBoundsCoordinates() {
        XCTAssertTrue(
            ZenMuxVisualLocalization(
                found: true,
                x: 500,
                y: 250,
                description: "Settings button"
            ).isValid
        )
        XCTAssertFalse(
            ZenMuxVisualLocalization(
                found: true,
                x: 1_001,
                y: 250,
                description: "Invalid point"
            ).isValid
        )
    }

    func testWebCredentialStoreAcceptsOnlyCanonicalHTTPSOrigins() {
        XCTAssertEqual(
            WebCredentialStore.secureOrigin(from: "https://Accounts.Google.com/signin/v2"),
            "https://accounts.google.com"
        )
        XCTAssertEqual(
            WebCredentialStore.secureOrigin(from: "https://example.com:8443/login"),
            "https://example.com:8443"
        )
        XCTAssertNil(WebCredentialStore.secureOrigin(from: "http://accounts.google.com"))
        XCTAssertNil(WebCredentialStore.secureOrigin(from: "javascript:alert(1)"))
    }

    func testBrowserAutomationToolNamesMatchProviderContract() {
        XCTAssertEqual(BrowserAutomationAction.Kind.inspectPage.rawValue, "inspect_page")
        XCTAssertEqual(BrowserAutomationAction.Kind.typeText.rawValue, "type_text")
        XCTAssertEqual(BrowserAutomationAction.Kind.pressKey.rawValue, "press_key")
        XCTAssertEqual(BrowserAutomationAction.Kind.waitForElement.rawValue, "wait_for_element")
        XCTAssertEqual(BrowserAutomationAction.Kind.inspectVisualPage.rawValue, "inspect_visual_page")
        XCTAssertEqual(BrowserAutomationAction.Kind.visualClick.rawValue, "visual_click")
        XCTAssertEqual(BrowserAutomationAction.Kind.openTab.rawValue, "open_tab")
    }

    func testVisualAutomationCoordinatesAreBoundedAndNormalized() throws {
        XCTAssertNil(BrowserAutomationPoint(x: -1, y: 500))
        XCTAssertNil(BrowserAutomationPoint(x: 500, y: 1_001))

        let point = try XCTUnwrap(BrowserAutomationPoint(x: 250, y: 750))
        XCTAssertEqual(point.point(in: CGSize(width: 800, height: 600)), CGPoint(x: 200, y: 450))
    }

    func testBrowserAutomationTargetPrefersSafeStructuredDOMData() throws {
        let selector = "button[aria-label=\"Review's inbox\"]"
        let target = BrowserAutomationTarget(
            index: 7,
            ref: "e-stable_ref-1",
            selector: selector,
            matchIndex: 99
        )
        let script = try XCTUnwrap(target.javaScriptResolver())
        let selectorLine = try XCTUnwrap(
            script.split(separator: "\n").first(where: { $0.contains("const targetSelector =") })
        )
        let encodedSelector = selectorLine
            .trimmingCharacters(in: .whitespaces)
            .dropFirst("const targetSelector = ".count)
            .dropLast()

        XCTAssertEqual(
            try JSONDecoder().decode(String.self, from: Data(encodedSelector.utf8)),
            selector
        )
        XCTAssertTrue(script.contains("const targetRef = \"e-stable_ref-1\";"))
        XCTAssertTrue(script.contains("const targetMatchIndex = 50;"))
    }

    func testBrowserAutomationTargetRejectsInvalidRefsAndOversizedSelectors() {
        let target = BrowserAutomationTarget(
            index: nil,
            ref: "not a valid ref",
            selector: String(repeating: "a", count: BrowserAutomationTarget.maximumSelectorLength + 1),
            matchIndex: nil
        )

        XCTAssertFalse(target.isSpecified)
        XCTAssertNil(target.javaScriptResolver())
    }

    func testRoutineBrowserControlsDoNotRequireRepeatedConfirmation() {
        XCTAssertFalse(BrowserAutomationInteractionPolicy.requiresConfirmation(controlType: nil))
        XCTAssertFalse(BrowserAutomationInteractionPolicy.requiresConfirmation(controlType: "button"))
        XCTAssertFalse(BrowserAutomationInteractionPolicy.requiresConfirmation(controlType: "checkbox"))
        XCTAssertFalse(BrowserAutomationInteractionPolicy.requiresConfirmation(controlType: "radio"))
        XCTAssertTrue(BrowserAutomationInteractionPolicy.requiresConfirmation(controlType: "submit"))
    }

    func testOAuthPopupKeepsNativeOpenerRelationship() {
        let request = CefWindowOpenRequest(
            targetURL: URL(string: "https://accounts.google.com/o/oauth2/auth")!,
            disposition: .newPopup,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .allowNativePopup)
    }

    func testRegularPopupStaysInAstraTab() {
        let request = CefWindowOpenRequest(
            targetURL: URL(string: "https://example.com/popup")!,
            disposition: .newPopup,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .handled)
    }

    func testGoogleIdentityForegroundTabIsPromotedToNativePopup() {
        let request = CefWindowOpenRequest(
            targetURL: URL(string: "https://accounts.google.com/gsi/select")!,
            disposition: .newForegroundTab,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .allowNativePopup)
        XCTAssertFalse(BrowserWindowOpenPolicy.shouldHandleNewTabInApp(
            for: URL(string: "https://accounts.google.com/gsi/select")!
        ))
    }

    func testRegionalGoogleIdentityURLUsesNativePopup() {
        let request = CefWindowOpenRequest(
            targetURL: URL(string: "https://accounts.google.co.jp/signin")!,
            disposition: .newWindow,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .allowNativePopup)
    }

    func testResourceCompatibilityDoesNotMutateGoogleIdentityPages() {
        XCTAssertFalse(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://accounts.google.com/gsi/select")!
        ))
        XCTAssertFalse(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://accounts.google.co.jp/signin")!
        ))
        XCTAssertFalse(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://accounts.youtube.com/accounts/SetSID")!
        ))
        XCTAssertTrue(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://www.google.com/search?q=test")!
        ))
        XCTAssertTrue(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://www.163.com/")!
        ))
    }

    @MainActor
    func testXUsesSystemMediaEngine() {
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "https://x.com/example/status/1")!
        ))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "https://mobile.twitter.com/example/status/1")!
        ))
    }

    @MainActor
    func testSystemMediaDataStoreIsStableAndProfileScoped() {
        let first = SystemMediaCompatibilityPolicy.dataStoreIdentifier(forProfileId: "Default")
        let repeated = SystemMediaCompatibilityPolicy.dataStoreIdentifier(forProfileId: "Default")
        let second = SystemMediaCompatibilityPolicy.dataStoreIdentifier(forProfileId: "Profile-work")

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
    }

    func testRegularNewWindowStillRoutesIntoBrowserTab() {
        let request = CefWindowOpenRequest(
            targetURL: URL(string: "https://example.com/article")!,
            disposition: .newForegroundTab,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .handled)
        XCTAssertTrue(BrowserWindowOpenPolicy.shouldHandleNewTabInApp(
            for: URL(string: "https://example.com/article")!
        ))
    }

    @MainActor
    func testSystemMediaEngineHandlesKnownH264NewsDomains() {
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "https://www.bbc.com/video")!
        ))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "https://news.yahoo.com/")!
        ))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "https://static.bbci.co.uk/video")!
        ))
        XCTAssertFalse(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "https://www.youtube.com/watch?v=example")!
        ))
        XCTAssertFalse(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
            for: URL(string: "http://www.bbc.com/video")!
        ))
    }

    func testSafariCompatibleUserAgentLooksLikeASupportedBrowser() {
        XCTAssertTrue(SupportedBrowserUserAgent.safariCompatibleUserAgent.contains("Version/"))
        XCTAssertTrue(SupportedBrowserUserAgent.safariCompatibleUserAgent.contains("Safari/"))
        XCTAssertTrue(SupportedBrowserUserAgent.chromiumProduct.hasPrefix("Chrome/"))
    }

    @MainActor
    func testHttpsPagesShareProfileScopedWebKitStore() {
        XCTAssertTrue(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://accounts.google.com/")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
        XCTAssertTrue(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://www.bbc.com/news")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
        XCTAssertTrue(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://www.youtube.com/")!,
            profileId: "Profile-work",
            allowsCredentialStorage: true
        ))
        XCTAssertFalse(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "chrome://newtab")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
    }

    @MainActor
    func testSystemMediaEngineRemembersAutomaticallyDetectedDomains() {
        let detectedURL = URL(string: "https://media-compatibility-test.invalid/watch")!

        XCTAssertFalse(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(for: detectedURL))
        SystemMediaCompatibilityPolicy.rememberDetectedMediaIncompatibility(for: detectedURL)
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(for: detectedURL))
    }

    func testBrowserAutomationAllowsMultiStepTasksToFinish() {
        XCTAssertEqual(ZenMuxChatSession.maximumBrowserToolRounds, 32)
    }

    func testBrowserMutationsRequireFreshStateInspection() {
        XCTAssertEqual(BrowserAutomationVerificationPolicy.requiredStableInspectionCount, 2)
        XCTAssertTrue(BrowserAutomationVerificationPolicy.requiresPostActionInspection(.click))
        XCTAssertTrue(BrowserAutomationVerificationPolicy.requiresPostActionInspection(.typeText))
        XCTAssertTrue(BrowserAutomationVerificationPolicy.requiresPostActionInspection(.visualClick))
        XCTAssertFalse(BrowserAutomationVerificationPolicy.requiresPostActionInspection(.inspectPage))
        XCTAssertTrue(BrowserAutomationVerificationPolicy.verifiesPageState(.inspectPage))
        XCTAssertTrue(BrowserAutomationVerificationPolicy.verifiesPageState(.waitForElement))
        XCTAssertFalse(BrowserAutomationVerificationPolicy.verifiesPageState(.inspectVisualPage))
    }

    @MainActor
    func testPartialInspectionPreservesReadableContentWhenElementInspectionTimesOut() throws {
        let encoded = try XCTUnwrap(CefWebContentWrapper.partialInspectionJSON(
            title: "Large news page",
            url: "https://example.com/news",
            text: "Headline one\nHeadline two"
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["partial"] as? Bool, true)
        XCTAssertEqual(payload["text"] as? String, "Headline one\nHeadline two")
        XCTAssertEqual((payload["elements"] as? [Any])?.count, 0)
    }

    func testComposerReturnKeySendsWhileModifiedReturnCreatesNewline() {
        XCTAssertTrue(ZenMuxComposerKeyPolicy.shouldSend(
            keyCode: 36,
            modifierFlags: [],
            hasMarkedText: false
        ))
        XCTAssertFalse(ZenMuxComposerKeyPolicy.shouldSend(
            keyCode: 36,
            modifierFlags: [.shift],
            hasMarkedText: false
        ))
        XCTAssertFalse(ZenMuxComposerKeyPolicy.shouldSend(
            keyCode: 36,
            modifierFlags: [],
            hasMarkedText: true
        ))
    }
}
