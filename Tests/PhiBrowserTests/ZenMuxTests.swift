// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CryptoKit
import CefKit
import JavaScriptCore
import Security
import XCTest
@testable import Phi

final class ZenMuxTests: XCTestCase {
    func testZenMuxBuildDoesNotRequireLegacyAuthentication() {
        XCTAssertFalse(PhiBuildCapabilities.supportsAuthentication)
        XCTAssertTrue(PhiBuildCapabilities.supportsAI)
        XCTAssertFalse(PhiBuildCapabilities.supportsSoftwareUpdates)
        XCTAssertFalse(PhiBuildCapabilities.supportsLegacyRollback)
        XCTAssertFalse(PhiBuildCapabilities.supportsPhiOriginMenus)
    }

    func testBrowserAccountPrivacyDoesNotAssociateGoogleAccountsWithAstra() throws {
        var configuration = CefConfiguration.default
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaultProfileURL = rootURL.appendingPathComponent("Default", isDirectory: true)
        let preferencesURL = defaultProfileURL.appendingPathComponent("Preferences", isDirectory: false)
        try FileManager.default.createDirectory(at: defaultProfileURL, withIntermediateDirectories: true)
        try Data("{\"existing\":{\"value\":7}}".utf8).write(to: preferencesURL)

        CefBrowserAccountPrivacyPolicy.apply(to: &configuration)
        try CefBrowserAccountPrivacyPolicy.prepareProfile(at: rootURL)

        XCTAssertTrue(
            configuration.extraCommandLineSwitches.keys.contains(
                CefBrowserAccountPrivacyPolicy.disableSyncSwitch
            )
        )
        let data = try? Data(contentsOf: preferencesURL)
        let preferences = data.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let signin = preferences?["signin"] as? [String: Any]
        XCTAssertEqual(signin?["allowed"] as? Bool, false)
        let existing = preferences?["existing"] as? [String: Any]
        XCTAssertEqual(existing?["value"] as? Int, 7)
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

    func testModelCapabilitiesMatchZenMuxCatalog() {
        XCTAssertTrue(ZenMuxModel.geminiFlash.supportsVisualBrowserControl)
        XCTAssertTrue(ZenMuxModel.grok.supportsVisualBrowserControl)
        XCTAssertFalse(ZenMuxModel.glm.supportsVisualBrowserControl)
        XCTAssertTrue(ZenMuxModel.geminiFlash.supportsImageInput)
        XCTAssertTrue(ZenMuxModel.grok.supportsImageInput)
        XCTAssertFalse(ZenMuxModel.glm.supportsImageInput)
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
        XCTAssertNil(ZenMuxChatSession.youtubeEvidenceInstruction(
            pageURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            transcriptAvailable: false,
            videoAnalysisAvailable: true
        ))
    }

    func testYouTubeVideoAnalysisRequestUsesExplicitVertexFileData() throws {
        let videoURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let data = try APIClient.makeZenMuxYouTubeVideoAnalysisRequest(videoURL: videoURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let fileData = try XCTUnwrap(parts.last?["fileData"] as? [String: Any])

        XCTAssertEqual(fileData["fileUri"] as? String, videoURL)
        XCTAssertEqual(fileData["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(
            (object["generationConfig"] as? [String: Any])?["temperature"] as? Int,
            0
        )
    }

    func testYouTubeVideoAnalysisRejectsNonYouTubeURLs() {
        XCTAssertThrowsError(
            try APIClient.makeZenMuxYouTubeVideoAnalysisRequest(
                videoURL: "https://example.com/video.mp4"
            )
        )
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

    func testMultimodalMessagesUseOpenAICompatibleImageParts() throws {
        let firstDataURL = "data:image/jpeg;base64,ZmFrZQ=="
        let secondDataURL = "data:image/png;base64,aW1hZ2U="
        let message = ZenMuxChatRequestMessage.multimodalUserMessage(
            text: "Compare these images",
            imageDataURLs: [firstDataURL, secondDataURL]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(message)
            ) as? [String: Any]
        )
        let parts = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "Compare these images")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual(
            (parts[1]["image_url"] as? [String: Any])?["url"] as? String,
            firstDataURL
        )
        XCTAssertEqual(
            (parts[1]["image_url"] as? [String: Any])?["detail"] as? String,
            "high"
        )
        XCTAssertEqual(
            (parts[2]["image_url"] as? [String: Any])?["url"] as? String,
            secondDataURL
        )
    }

    func testVertexChatRequestSendsImagesAsInlineData() throws {
        let message = ZenMuxChatRequestMessage.multimodalUserMessage(
            text: "Describe this image",
            imageDataURLs: ["data:image/png;base64,aW1hZ2U="]
        )
        let data = try APIClient.makeZenMuxVertexChatRequestData(
            model: .geminiFlash,
            messages: [
                ZenMuxChatRequestMessage(role: "system", content: "Be concise"),
                message,
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let systemInstruction = try XCTUnwrap(object["systemInstruction"] as? [String: Any])
        let systemParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        XCTAssertEqual(systemParts.first?["text"] as? String, "Be concise")

        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let inlineData = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/png")
        XCTAssertEqual(inlineData["data"] as? String, "aW1hZ2U=")
        XCTAssertNil(parts[1]["fileData"])
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("temp/chat-completions") == true)
    }

    func testVertexChatRequestPreservesFunctionCallsAndResponses() throws {
        let call = ZenMuxToolCall(
            id: "call-1",
            type: "function",
            function: .init(name: "inspect_page", arguments: "{\"index\":2}"),
            thoughtSignature: "signature"
        )
        let data = try APIClient.makeZenMuxVertexChatRequestData(
            model: .geminiFlash,
            messages: [
                ZenMuxChatRequestMessage(role: "user", content: "Inspect the page"),
                ZenMuxChatRequestMessage(
                    role: "assistant",
                    content: nil,
                    toolCalls: [call]
                ),
                ZenMuxChatRequestMessage(
                    role: "tool",
                    content: "Browser tool succeeded",
                    toolCallID: "call-1"
                ),
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let modelParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(modelParts[0]["functionCall"] as? [String: Any])
        XCTAssertEqual(functionCall["name"] as? String, "inspect_page")
        XCTAssertEqual((functionCall["args"] as? [String: Any])?["index"] as? Int, 2)
        XCTAssertEqual(modelParts[0]["thoughtSignature"] as? String, "signature")

        let responseParts = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try XCTUnwrap(
            responseParts[0]["functionResponse"] as? [String: Any]
        )
        XCTAssertEqual(functionResponse["id"] as? String, "call-1")
        XCTAssertEqual(functionResponse["name"] as? String, "inspect_page")
        XCTAssertEqual(
            (functionResponse["response"] as? [String: Any])?["output"] as? String,
            "Browser tool succeeded"
        )
    }

    func testVertexChatResponseDecodesTextAndFunctionCalls() throws {
        let data = Data(#"""
        {
          "candidates": [{
            "content": {
              "role": "model",
              "parts": [
                {"text": "Working on it."},
                {
                  "functionCall": {
                    "id": "call-2",
                    "name": "click",
                    "args": {"index": 3}
                  },
                  "thoughtSignature": "signature-2"
                }
              ]
            }
          }]
        }
        """#.utf8)
        let completion = try APIClient.decodeZenMuxVertexChatResponse(data)

        XCTAssertEqual(completion.content, "Working on it.")
        XCTAssertEqual(completion.toolCalls.count, 1)
        XCTAssertEqual(completion.toolCalls[0].id, "call-2")
        XCTAssertEqual(completion.toolCalls[0].function.name, "click")
        XCTAssertEqual(completion.toolCalls[0].function.arguments, "{\"index\":3}")
        XCTAssertEqual(completion.toolCalls[0].thoughtSignature, "signature-2")
    }

    func testTextOnlyMessagesKeepStringContent() throws {
        let message = ZenMuxChatRequestMessage(role: "user", content: "Hello")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(message)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["content"] as? String, "Hello")
    }

    func testAutomaticPageImageIsCombinedWithManualAttachments() throws {
        let manualDataURL = "data:image/png;base64,bWFudWFs"
        let pageDataURL = "data:image/jpeg;base64,cGFnZQ=="
        let message = ZenMuxChatVisionContext.requestMessage(
            text: "What is visible here?",
            manualImageDataURLs: [manualDataURL],
            currentPageImageDataURL: pageDataURL
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(message)
            ) as? [String: Any]
        )
        let parts = try XCTUnwrap(object["content"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(
            (parts[1]["image_url"] as? [String: Any])?["url"] as? String,
            manualDataURL
        )
        XCTAssertEqual(
            (parts[2]["image_url"] as? [String: Any])?["url"] as? String,
            pageDataURL
        )
    }

    func testImageAttachmentPreparationProducesBoundedVisionInput() throws {
        let source = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9YP8b1sAAAAASUVORK5CYII="
        ))
        let attachment = try ZenMuxImageAttachment.prepare(
            data: source,
            filename: "coin.png"
        )

        XCTAssertEqual(attachment.filename, "coin.png")
        XCTAssertTrue(["image/png", "image/jpeg"].contains(attachment.mimeType))
        XCTAssertLessThanOrEqual(
            attachment.data.count,
            ZenMuxImageAttachment.maximumEncodedBytes
        )
        XCTAssertTrue(attachment.dataURL.hasPrefix("data:image/"))
    }

    func testImageAttachmentSelectionIsLimitedToFiveAndSupportsRemoval() {
        let session = ZenMuxChatSession()
        let candidates = (0..<7).map { index in
            ZenMuxImageAttachment(
                filename: "image-\(index).png",
                mimeType: "image/png",
                data: Data([UInt8(index)])
            )
        }

        session.addImageAttachments(candidates)

        XCTAssertEqual(session.imageAttachments.count, 5)
        XCTAssertTrue(session.canSend)
        session.beginLoadingImageAttachments()
        XCTAssertFalse(session.canSend)
        session.finishLoadingImageAttachments()
        XCTAssertTrue(session.canSend)
        let removedID = session.imageAttachments[2].id
        session.removeImageAttachment(id: removedID)
        XCTAssertEqual(session.imageAttachments.count, 4)
        XCTAssertFalse(session.imageAttachments.contains { $0.id == removedID })
    }

    func testVisiblePageDataURLUsesImageAttachmentPipeline() throws {
        let pngData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9YP8b1sAAAAASUVORK5CYII="
        ))
        let attachment = try ZenMuxImageAttachment.prepare(
            dataURL: "data:image/png;base64,\(pngData.base64EncodedString())",
            filename: "visible-page.png",
            origin: .visiblePage
        )
        let session = ZenMuxChatSession()

        session.addImageAttachments([attachment])

        XCTAssertEqual(session.imageAttachments.count, 1)
        XCTAssertEqual(session.imageAttachments[0].filename, "visible-page.png")
        XCTAssertEqual(session.imageAttachments[0].origin, .visiblePage)
        XCTAssertTrue(session.imageAttachments[0].dataURL.hasPrefix("data:image/"))
        session.removeImageAttachment(id: attachment.id)
        XCTAssertTrue(session.imageAttachments.isEmpty)
        XCTAssertEqual(ZenMuxChatVisionContext.visiblePageCaptureAction.kind, .inspectVisualPage)
    }

    func testVisiblePageDataURLRejectsNonImagePayloads() {
        XCTAssertThrowsError(try ZenMuxImageAttachment.prepare(
            dataURL: "data:text/plain;base64,SGVsbG8=",
            filename: "visible-page.png"
        ))
    }

    func testImagePasteboardReaderRecognizesImageDataWithoutChangingTextPaste() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9YP8b1sAAAAASUVORK5CYII="
        ))
        let imageItem = NSPasteboardItem()
        imageItem.setData(imageData, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([imageItem]))

        let sources = ZenMuxImagePasteboardReader.sources(from: pasteboard)
        XCTAssertEqual(sources.count, 1)
        let attachment = try sources[0].load()
        XCTAssertTrue(attachment.filename.hasPrefix("pasted-image-"))
        XCTAssertTrue(attachment.dataURL.hasPrefix("data:image/"))

        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        XCTAssertTrue(ZenMuxImagePasteboardReader.sources(from: pasteboard).isEmpty)
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

    func testXOAuthKeepsNativeOpenerRelationship() {
        let authorizationURL = URL(
            string: "https://x.com/i/oauth2/authorize?client_id=grok"
        )!
        let request = CefWindowOpenRequest(
            targetURL: authorizationURL,
            disposition: .newPopup,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .allowNativePopup)
        XCTAssertFalse(BrowserWindowOpenPolicy.shouldHandleNewTabInApp(for: authorizationURL))
        XCTAssertFalse(WebResourceCompatibilityPolicy.permitsPageMutation(for: authorizationURL))
    }

    func testRegularXLinkDoesNotBecomeIdentityPopup() {
        let regularURL = URL(string: "https://x.com/xai/status/1")!
        let request = CefWindowOpenRequest(
            targetURL: regularURL,
            disposition: .newForegroundTab,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .handled)
        XCTAssertTrue(BrowserWindowOpenPolicy.shouldHandleNewTabInApp(for: regularURL))
        XCTAssertFalse(WebResourceCompatibilityPolicy.permitsPageMutation(for: regularURL))
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
        XCTAssertFalse(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://www.google.com/search?q=test")!
        ))
        XCTAssertTrue(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://www.163.com/")!
        ))
        XCTAssertTrue(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://www.bilibili.com/video/BV1test")!
        ))
        XCTAssertTrue(WebResourceCompatibilityPolicy.permitsPageMutation(
            for: URL(string: "https://www.acfun.cn/v/ac1")!
        ))
    }

    @MainActor
    func testXUsesPersistentWebKitForSystemMediaAndNativeShield() {
        let xURL = URL(string: "https://x.com/example/status/1")!
        let twitterURL = URL(string: "https://mobile.twitter.com/example/status/1")!

        XCTAssertTrue(SystemMediaCompatibilityPolicy.allowsAutomaticFallback(for: xURL))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.allowsAutomaticFallback(for: twitterURL))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(for: xURL))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(for: twitterURL))
        XCTAssertTrue(WebContentEnginePolicy.usesPersistentWebKit(
            for: xURL,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
    }

    func testXSpamShieldMatchesLocallyAndHonorsWhitelist() throws {
        let liteData = Data("""
        {
          "version": "test-v1",
          "labels": { "p": "porn_bot", "s": "spam" },
          "entries": [
            ["100", "JunkAccount", "sha"],
            ["101", "WhitelistedAccount", "pha"]
          ]
        }
        """.utf8)
        let whitelistData = Data("""
        {
          "count": 1,
          "list": [
            { "handle": "whitelistedaccount", "x_user_id": "101", "last_scored": 1 }
          ]
        }
        """.utf8)

        let snapshot = try XSpamShieldListPolicy.decodeSnapshot(
            liteData: liteData,
            whitelistData: whitelistData
        )
        let matches = snapshot.matches(
            handles: ["@JUNKACCOUNT", "whitelistedaccount", "junkaccount"],
            hiddenHandles: ["junkaccount"]
        )

        XCTAssertEqual(matches, [
            XSpamShieldMatch(handle: "junkaccount", label: "spam", isHidden: true),
        ])
    }

    func testXSpamShieldAcceptsCurrentUpstreamLiteSchema() throws {
        let liteData = Data("""
        {
          "schema": 2,
          "generatedAt": 1787724062659,
          "count": 1,
          "labels": { "p": "porn_bot", "s": "spam" },
          "entries": [["", "UpstreamAccount", "ppa"]]
        }
        """.utf8)
        let whitelistData = Data("""
        {
          "count": 0,
          "generatedAt": 1787572861071,
          "list": []
        }
        """.utf8)

        let snapshot = try XSpamShieldListPolicy.decodeSnapshot(
            liteData: liteData,
            whitelistData: whitelistData
        )

        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(snapshot.version, "1787724062659")
        XCTAssertEqual(
            snapshot.matches(handles: ["upstreamaccount"], hiddenHandles: []),
            [XSpamShieldMatch(handle: "upstreamaccount", label: "porn_bot", isHidden: false)]
        )
    }

    func testXSpamShieldScriptKeepsPageDataLocal() {
        let script = XSpamShieldWebPolicy.javaScript(
            guardLabel: "Guard",
            junkLabel: "Junk account",
            hideLabel: "Block",
            undoLabel: "Undo",
            hiddenMessage: "Blocked @%@",
            signInMessage: "Sign in to X to block these accounts",
            blockFailedMessage: "Could not block all accounts. Try again later."
        )

        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("astraXSpamShield"))
        XCTAssertTrue(script.contains("handler.postMessage({ type: 'scan', handles })"))
        XCTAssertFalse(script.contains("x.zuoluo.tv"))
        XCTAssertFalse(script.contains("XMLHttpRequest"))
    }

    func testXSpamShieldScriptBlocksDiscoveredAccountsFromGuardPill() {
        let script = XSpamShieldWebPolicy.javaScript(
            guardLabel: "Guard",
            junkLabel: "Junk account",
            hideLabel: "Block",
            undoLabel: "Undo",
            hiddenMessage: "Blocked @%@",
            signInMessage: "Sign in to X to block these accounts",
            blockFailedMessage: "Could not block all accounts. Try again later."
        )

        XCTAssertTrue(script.contains("/i/api/1.1/blocks/create.json"))
        XCTAssertTrue(script.contains("blockDiscovered([match.handle])"))
        XCTAssertTrue(script.contains("screen_name="))
        XCTAssertTrue(script.contains("blockDiscovered"))
        XCTAssertTrue(script.contains("done + '/' + total"))
        XCTAssertTrue(script.contains("addEventListener('click'"))
        XCTAssertFalse(script.contains("pointer-events:none"))
    }

    func testXImageZoomOnlySupportsXHosts() {
        XCTAssertTrue(XImageZoomWebPolicy.supports(host: "x.com"))
        XCTAssertTrue(XImageZoomWebPolicy.supports(host: "mobile.twitter.com"))
        XCTAssertTrue(XImageZoomWebPolicy.supports(host: "X.COM."))
        XCTAssertFalse(XImageZoomWebPolicy.supports(host: "x.com.example.org"))
        XCTAssertFalse(XImageZoomWebPolicy.supports(host: "example.com"))
        XCTAssertFalse(XImageZoomWebPolicy.supports(host: nil))
    }

    func testXImageZoomScriptTargetsMediaViewerAndSupportsZoomAndPan() {
        let script = XImageZoomWebPolicy.javaScript

        XCTAssertTrue(script.contains("pbs.twimg.com/media/"))
        XCTAssertTrue(script.contains("[role=\"dialog\"] img"))
        XCTAssertTrue(script.contains("[role=\"dialog\"] video"))
        XCTAssertTrue(script.contains("gesturestart"))
        XCTAssertTrue(script.contains("gesturechange"))
        XCTAssertTrue(script.contains("addEventListener('wheel'"))
        XCTAssertTrue(script.contains("addEventListener('dblclick'"))
        XCTAssertTrue(script.contains("addEventListener('pointermove'"))
        XCTAssertTrue(script.contains("const maximumScale = 8"))
        XCTAssertTrue(script.contains("window.__astraXImageZoomInstalled"))
        XCTAssertTrue(script.contains("window.__astraXImageZoom = Object.freeze"))
        XCTAssertTrue(script.contains("magnify(rawMagnification)"))
        XCTAssertTrue(script.contains("__astra-x-image-zoom-controls"))
        XCTAssertTrue(script.contains("slider.type = 'range'"))
        XCTAssertTrue(script.contains("makeButton('−'"))
        XCTAssertTrue(script.contains("makeButton('+'"))
        XCTAssertTrue(script.contains("makeButton('↺'"))
    }

    func testXImageZoomNativeMagnificationBuildsSafeBridgeCalls() {
        XCTAssertEqual(
            XImageZoomWebPolicy.nativeMagnificationJavaScript(0.25),
            "window.__astraXImageZoom?.magnify(0.25);"
        )
        XCTAssertEqual(
            XImageZoomWebPolicy.nativeMagnificationJavaScript(-0.125),
            "window.__astraXImageZoom?.magnify(-0.125);"
        )
        XCTAssertNil(XImageZoomWebPolicy.nativeMagnificationJavaScript(0))
        XCTAssertNil(XImageZoomWebPolicy.nativeMagnificationJavaScript(.nan))
        XCTAssertNil(XImageZoomWebPolicy.nativeMagnificationJavaScript(.infinity))
    }

    func testXImageZoomScriptParsesAndLeavesOtherHostsUntouched() throws {
        let context = try XCTUnwrap(JSContext())
        var scriptException: JSValue?
        context.exceptionHandler = { _, exception in
            scriptException = exception
        }
        context.evaluateScript(
            """
            globalThis.window = globalThis;
            globalThis.location = { hostname: 'example.com' };
            """,
            withSourceURL: nil
        )

        context.evaluateScript(XImageZoomWebPolicy.javaScript, withSourceURL: nil)

        XCTAssertNil(scriptException?.toString())
        XCTAssertFalse(
            context.evaluateScript("Boolean(window.__astraXImageZoomInstalled)")?.toBool() ?? true
        )
    }

    func testXImageZoomScriptInstallsViewerHooksOnX() throws {
        let context = try XCTUnwrap(JSContext())
        var scriptException: JSValue?
        context.exceptionHandler = { _, exception in
            scriptException = exception
        }
        context.evaluateScript(
            """
            globalThis.window = globalThis;
            globalThis.location = { hostname: 'x.com' };
            globalThis.__listeners = [];
            globalThis.document = {
              documentElement: {},
              addEventListener: (name) => __listeners.push(name),
              querySelectorAll: () => []
            };
            globalThis.MutationObserver = function () { this.observe = function () {}; };
            globalThis.HTMLImageElement = function () {};
            globalThis.getComputedStyle = () => ({ display: 'block', visibility: 'visible' });
            globalThis.addEventListener = (name) => __listeners.push(name);
            globalThis.requestAnimationFrame = (callback) => callback();
            """,
            withSourceURL: nil
        )

        context.evaluateScript(XImageZoomWebPolicy.javaScript, withSourceURL: nil)

        XCTAssertNil(scriptException?.toString())
        XCTAssertTrue(
            context.evaluateScript("Boolean(window.__astraXImageZoomInstalled)")?.toBool() ?? false
        )
        XCTAssertTrue(context.evaluateScript("__listeners.includes('gesturestart')")?.toBool() ?? false)
        XCTAssertTrue(context.evaluateScript("__listeners.includes('wheel')")?.toBool() ?? false)
        XCTAssertTrue(context.evaluateScript("__listeners.includes('pointermove')")?.toBool() ?? false)
    }

    func testXImageZoomNativeBridgeMagnifiesTheVisibleXImage() throws {
        let context = try XCTUnwrap(JSContext())
        var scriptException: JSValue?
        context.exceptionHandler = { _, exception in
            scriptException = exception
        }
        context.evaluateScript(
            """
            globalThis.window = globalThis;
            globalThis.location = { hostname: 'x.com' };
            globalThis.innerWidth = 1200;
            globalThis.innerHeight = 900;
            globalThis.__styleValues = {};
            globalThis.__offscreenStyleValues = {};
            globalThis.__videoStyleValues = {};
            globalThis.__listeners = [];
            globalThis.__documentListeners = {};
            globalThis.__controlHost = null;
            globalThis.__makeElement = (tag) => ({
              tagName: String(tag).toUpperCase(),
              style: {
                values: {},
                setProperty(name, value) { this.values[name] = value; }
              },
              attributes: {},
              listeners: {},
              children: [],
              setAttribute(name, value) { this.attributes[name] = value; },
              addEventListener(name, callback) { this.listeners[name] = callback; },
              append(...children) { this.children.push(...children); }
            });
            globalThis.HTMLImageElement = function () {};
            globalThis.HTMLVideoElement = function () {};
            globalThis.__viewer = {
              getBoundingClientRect: () => ({ width: 900, height: 700, left: 0, top: 0 })
            };
            globalThis.__image = new HTMLImageElement();
            __image.currentSrc = 'https://pbs.twimg.com/media/example.jpg';
            __image.src = __image.currentSrc;
            __image.style = {
              getPropertyValue: (name) => __styleValues[name]?.value || '',
              getPropertyPriority: (name) => __styleValues[name]?.priority || '',
              setProperty: (name, value, priority) => {
                __styleValues[name] = { value, priority };
              },
              removeProperty: (name) => { delete __styleValues[name]; }
            };
            __image.getBoundingClientRect = () => ({
              width: 800, height: 600, left: 100, top: 100
            });
            __image.closest = () => __viewer;
            __image.getAttribute = () => null;
            __image.setAttribute = () => {};
            __image.removeAttribute = () => {};
            globalThis.__offscreenImage = new HTMLImageElement();
            __offscreenImage.currentSrc = 'https://pbs.twimg.com/media/offscreen.jpg';
            __offscreenImage.src = __offscreenImage.currentSrc;
            __offscreenImage.style = {
              getPropertyValue: (name) => __offscreenStyleValues[name]?.value || '',
              getPropertyPriority: (name) => __offscreenStyleValues[name]?.priority || '',
              setProperty: (name, value, priority) => {
                __offscreenStyleValues[name] = { value, priority };
              },
              removeProperty: (name) => { delete __offscreenStyleValues[name]; }
            };
            __offscreenImage.getBoundingClientRect = () => ({
              width: 1600, height: 900, left: -2400, top: 0
            });
            __offscreenImage.closest = () => __viewer;
            __offscreenImage.getAttribute = () => null;
            __offscreenImage.setAttribute = () => {};
            __offscreenImage.removeAttribute = () => {};
            globalThis.__mediaElements = [__offscreenImage, __image];
            globalThis.__hitStack = [__image];
            globalThis.document = {
              documentElement: { lang: 'zh-CN' },
              body: { appendChild: (element) => { __controlHost = element; } },
              createElement: (tag) => __makeElement(tag),
              addEventListener: (name, callback) => {
                __listeners.push(name);
                __documentListeners[name] = callback;
              },
              querySelectorAll: () => __mediaElements,
              elementsFromPoint: () => __hitStack
            };
            globalThis.MutationObserver = function () { this.observe = function () {}; };
            globalThis.getComputedStyle = () => ({ display: 'block', visibility: 'visible' });
            globalThis.addEventListener = (name) => __listeners.push(name);
            globalThis.requestAnimationFrame = (callback) => callback();
            """,
            withSourceURL: nil
        )

        context.evaluateScript(XImageZoomWebPolicy.javaScript, withSourceURL: nil)
        let handled = context.evaluateScript("window.__astraXImageZoom.magnify(0.25)")
        let nativeTransform = context.evaluateScript("__styleValues.transform.value")

        XCTAssertNil(scriptException?.toString())
        XCTAssertTrue(handled?.toBool() ?? false)
        XCTAssertTrue(nativeTransform?.toString()?.contains("scale(1.284") ?? false)
        XCTAssertFalse(
            context.evaluateScript("Boolean(__offscreenStyleValues.transform)")?.toBool() ?? true
        )
        XCTAssertEqual(
            context.evaluateScript("__controlHost.id")?.toString(),
            "__astra-x-image-zoom-controls"
        )
        XCTAssertEqual(
            context.evaluateScript("__controlHost.style.values.display")?.toString(),
            "flex"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__controlHost.children.find((element) => element.type === 'range').min"
            )?.toString(),
            "1"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__controlHost.children.find((element) => element.type === 'range').max"
            )?.toString(),
            "8"
        )

        context.evaluateScript(
            """
            globalThis.__slider = __controlHost.children.find(
              (element) => element.type === 'range'
            );
            __slider.value = '3';
            __slider.listeners.input();
            """
        )

        XCTAssertNil(scriptException?.toString())
        XCTAssertTrue(
            context.evaluateScript("__styleValues.transform.value")?.toString()?
                .contains("scale(3)") ?? false
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__controlHost.children.find((element) => element.tagName === 'SPAN').textContent"
            )?.toString(),
            "300%"
        )

        context.evaluateScript(
            """
            globalThis.__pointerEvent = (overrides) => Object.assign({
              target: __image,
              button: 0,
              pointerId: 7,
              clientX: 400,
              clientY: 300,
              preventDefault() {},
              stopPropagation() {}
            }, overrides);
            __documentListeners.pointerdown(__pointerEvent({}));
            __documentListeners.pointermove(__pointerEvent({ clientX: 440, clientY: 330 }));
            """
        )

        XCTAssertNil(scriptException?.toString())
        XCTAssertTrue(
            context.evaluateScript("__styleValues.transform.value")?.toString()?
                .contains("translate3d(40px, 30px, 0) scale(3)") ?? false
        )

        context.evaluateScript(
            """
            globalThis.__zoomIn = __controlHost.children.find(
              (element) => element.textContent === '+'
            );
            __zoomIn.listeners.click({ preventDefault() {} });
            """
        )

        XCTAssertNil(scriptException?.toString())
        XCTAssertTrue(
            context.evaluateScript("__styleValues.transform.value")?.toString()?
                .contains("scale(3.75)") ?? false
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__controlHost.children.find((element) => element.tagName === 'SPAN').textContent"
            )?.toString(),
            "375%"
        )

        context.evaluateScript(
            """
            globalThis.__resetButton = __controlHost.children.find(
              (element) => element.textContent === '↺'
            );
            __resetButton.listeners.click({ preventDefault() {} });
            """
        )

        XCTAssertNil(scriptException?.toString())
        XCTAssertFalse(
            context.evaluateScript("Boolean(__styleValues.transform)")?.toBool() ?? true
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__controlHost.children.find((element) => element.tagName === 'SPAN').textContent"
            )?.toString(),
            "100%"
        )

        context.evaluateScript(
            """
            globalThis.__video = new HTMLVideoElement();
            __video.currentSrc = 'blob:https://x.com/active-video';
            __video.src = __video.currentSrc;
            __video.style = {
              getPropertyValue: (name) => __videoStyleValues[name]?.value || '',
              getPropertyPriority: (name) => __videoStyleValues[name]?.priority || '',
              setProperty: (name, value, priority) => {
                __videoStyleValues[name] = { value, priority };
              },
              removeProperty: (name) => { delete __videoStyleValues[name]; }
            };
            __video.getBoundingClientRect = () => ({
              width: 800, height: 600, left: 100, top: 100
            });
            __video.closest = () => __viewer;
            __video.getAttribute = () => null;
            __video.setAttribute = () => {};
            __video.removeAttribute = () => {};
            __mediaElements = [__offscreenImage, __image, __video];
            __hitStack = [__video, __image];
            window.__astraXImageZoom.magnify(0.5);
            __documentListeners.pointerdown(__pointerEvent({
              target: __video,
              pointerId: 9,
              clientX: 500,
              clientY: 400
            }));
            __documentListeners.pointermove(__pointerEvent({
              target: __video,
              pointerId: 9,
              clientX: 525,
              clientY: 420
            }));
            """
        )

        XCTAssertNil(scriptException?.toString())
        XCTAssertTrue(
            context.evaluateScript("__videoStyleValues.transform.value")?.toString()?
                .contains("translate3d(25px, 20px, 0) scale(1.648") ?? false
        )
        XCTAssertFalse(
            context.evaluateScript("Boolean(__styleValues.transform)")?.toBool() ?? true
        )
    }

    @MainActor
    func testPersistentMediaFallbackStillUsesStallDetection() {
        let mediaURL = URL(string: "https://www.163.com/video/article")!

        XCTAssertTrue(SystemMediaCompatibilityPolicy.allowsAutomaticFallback(for: mediaURL))
        XCTAssertTrue(SystemMediaCompatibilityPolicy.usesStallBasedAutomaticFallback(for: mediaURL))
    }

    @MainActor
    func testGrokRemainsInChromiumAfterMediaErrors() {
        let grokURL = URL(string: "https://grok.com/imagine")!

        XCTAssertFalse(SystemMediaCompatibilityPolicy.allowsAutomaticFallback(for: grokURL))
        SystemMediaCompatibilityPolicy.rememberDetectedMediaIncompatibility(for: grokURL)
        XCTAssertFalse(SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(for: grokURL))
        XCTAssertFalse(WebContentEnginePolicy.usesPersistentWebKit(
            for: grokURL,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
    }

    func testVisiblePageCaptureUsesTheCurrentlyRenderedEngine() {
        XCTAssertEqual(
            VisiblePageCaptureRoute.active(hasSystemMediaPage: true),
            .systemMedia
        )
        XCTAssertEqual(
            VisiblePageCaptureRoute.active(hasSystemMediaPage: false),
            .chromium
        )
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

    func testExtensionOnboardingFromUnmanagedChromiumWindowRoutesIntoAstra() {
        let route = UnmanagedChromiumWindowPolicy.routeURL(from: [
            URL(string: "chrome://newtab")!,
            URL(string: "https://example.com/extension-installed")!,
        ])

        XCTAssertEqual(route?.absoluteString, "https://example.com/extension-installed")
    }

    func testEmptyUnmanagedChromiumWindowDoesNotCreateAnotherTab() {
        XCTAssertNil(UnmanagedChromiumWindowPolicy.routeURL(from: [
            URL(string: "about:blank")!,
            URL(string: "chrome://newtab/")!,
        ]))
    }

    @MainActor
    func testOwnedChromeOverlayWindowIsNotCapturedAsUnmanaged() {
        let overlay = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        UnmanagedChromiumWindowPolicy.markAsOwnedOverlay(overlay)

        XCTAssertFalse(UnmanagedChromiumWindowPolicy.shouldCapture(overlay))
    }

    @MainActor
    func testStandaloneChromiumWindowIsStillCapturedAsUnmanaged() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )

        XCTAssertTrue(UnmanagedChromiumWindowPolicy.shouldCapture(window))
    }

    @MainActor
    func testChildWindowIsNotCapturedAsUnmanaged() {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        parent.addChildWindow(child, ordered: .above)

        XCTAssertFalse(UnmanagedChromiumWindowPolicy.shouldCapture(child))
    }

    func testYouTubeNewTabStaysInAstraInsteadOfNativePopup() {
        let request = CefWindowOpenRequest(
            targetURL: URL(string: "https://www.youtube.com/watch?v=example")!,
            disposition: .newForegroundTab,
            userGesture: true
        )

        XCTAssertEqual(BrowserWindowOpenPolicy.action(for: request), .handled)
        XCTAssertTrue(BrowserWindowOpenPolicy.shouldHandleNewTabInApp(
            for: URL(string: "https://www.youtube.com/watch?v=example")!
        ))
    }

    func testClosingARequestedTabMustNotCreateAnotherEngine() {
        XCTAssertFalse(CefWebContentClosePolicy.shouldCreateEngine(didRequestClose: true))
        XCTAssertTrue(CefWebContentClosePolicy.shouldCreateEngine(didRequestClose: false))
    }

    func testTabCloseFinishesEvenIfChromeWindowDestructionNeverArrives() {
        XCTAssertTrue(
            CefWebContentClosePolicy.shouldFinishTabCloseWithoutWaitingForWindowDestruction
        )
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

    @MainActor
    func testSystemMediaEngineHandlesMainlandVideoDomains() {
        let urls = [
            "https://www.bilibili.com/video/BV1example",
            "https://www.iqiyi.com/v_example.html",
            "https://v.qq.com/x/cover/example.html",
            "https://v.youku.com/v_show/id_example.html",
            "https://www.mgtv.com/b/example.html",
            "https://www.douyin.com/video/example",
            "https://www.ixigua.com/example",
            "https://www.acfun.cn/v/ac-example",
            "https://tv.cctv.com/example",
            "https://www.yangshipin.cn/video",
            "https://www.aiyifan.tv/play/example",
            "https://www.aiyifan.club/play/example",
            "https://www.aiyifan.com.cn/play/example",
            "https://www.iyf.tv/play/example",
            "https://www.yfsp.tv/play/example",
        ]

        for rawURL in urls {
            XCTAssertTrue(
                SystemMediaCompatibilityPolicy.requiresSystemMediaEngine(
                    for: URL(string: rawURL)!
                ),
                rawURL
            )
        }
    }

    func testSafariCompatibleUserAgentLooksLikeASupportedBrowser() {
        XCTAssertTrue(SupportedBrowserUserAgent.safariCompatibleUserAgent.contains("Version/"))
        XCTAssertTrue(SupportedBrowserUserAgent.safariCompatibleUserAgent.contains("Safari/"))
        XCTAssertTrue(SupportedBrowserUserAgent.chromiumProduct.hasPrefix("Chrome/"))
    }

    @MainActor
    func testRegularWebPagesUseChromeRuntimeAcrossProfiles() {
        XCTAssertFalse(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://accounts.google.com/")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
        XCTAssertTrue(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://www.bbc.com/news")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
        XCTAssertFalse(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://www.youtube.com/")!,
            profileId: "Profile-work",
            allowsCredentialStorage: true
        ))
        XCTAssertFalse(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://example.com/")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: false
        ))
        XCTAssertFalse(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "chrome://newtab")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true
        ))
        XCTAssertTrue(WebContentEnginePolicy.usesPersistentWebKit(
            for: URL(string: "https://example.com/")!,
            profileId: LocalStore.defaultProfileId,
            allowsCredentialStorage: true,
            forceSystemMediaEngine: true
        ))
    }

    func testSystemMediaEngineBlocksPageWebRTC() {
        let script = WebKitWebRTCPrivacyPolicy.javaScript

        XCTAssertTrue(script.contains("RTCPeerConnection"))
        XCTAssertTrue(script.contains("webkitRTCPeerConnection"))
        XCTAssertTrue(script.contains("configurable: false"))
    }

    func testCefExtensionCatalogExposesInstalledIconAndControls() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extensionId = "abcdefghijklmnopabcdefghijklmnop"
        let versionDirectory = root
            .appendingPathComponent("Default/Extensions", isDirectory: true)
            .appendingPathComponent(extensionId, isDirectory: true)
            .appendingPathComponent("1.2.3_0", isDirectory: true)
        let localeDirectory = versionDirectory
            .appendingPathComponent("_locales/en", isDirectory: true)
        try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest: [String: Any] = [
            "name": "__MSG_extensionName__",
            "version": "1.2.3",
            "default_locale": "en",
            "action": [
                "default_popup": "popup/index.html",
                "default_icon": ["16": "icon.png"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: versionDirectory.appendingPathComponent("manifest.json")
        )
        try JSONSerialization.data(withJSONObject: [
            "extensionName": ["message": "Fixture Extension"],
        ]).write(to: localeDirectory.appendingPathComponent("messages.json"))
        let iconData = Data([0x01, 0x02, 0x03, 0x04])
        try iconData.write(to: versionDirectory.appendingPathComponent("icon.png"))

        let suiteName = "CefExtensionCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = CefInstalledExtensionCatalog(rootURL: root, defaults: defaults)

        var info = try XCTUnwrap(catalog.installedInfo(
            profileId: "default",
            isDefaultProfile: true,
            isIncognito: false
        ).first)
        XCTAssertEqual(info["id"] as? String, extensionId)
        XCTAssertEqual(info["name"] as? String, "Fixture Extension")
        XCTAssertEqual(info["version"] as? String, "1.2.3")
        XCTAssertEqual(info["icon"] as? String, iconData.base64EncodedString())
        XCTAssertEqual(info["isPinned"] as? Bool, false)
        XCTAssertEqual(catalog.actionURL(
            extensionId: extensionId,
            profileId: "default",
            isDefaultProfile: true,
            isIncognito: false
        ), "chrome-extension://\(extensionId)/popup/index.html")

        catalog.setPinned(true, extensionId: extensionId, profileId: "default")
        info = try XCTUnwrap(catalog.installedInfo(
            profileId: "default",
            isDefaultProfile: true,
            isIncognito: false
        ).first)
        XCTAssertEqual(info["isPinned"] as? Bool, true)
        XCTAssertEqual(info["pinnedIndex"] as? Int, 0)
        XCTAssertTrue(catalog.installedInfo(
            profileId: "default",
            isDefaultProfile: true,
            isIncognito: true
        ).isEmpty)
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
