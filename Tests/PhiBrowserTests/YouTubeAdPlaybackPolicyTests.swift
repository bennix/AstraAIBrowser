// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import JavaScriptCore
import XCTest
@testable import Phi

final class YouTubeAdPlaybackPolicyTests: XCTestCase {
    func testMediaDownloadPolicyRejectsTopLevelDRM() throws {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "has_drm": true,
            "formats": [["format_id": "encrypted", "has_drm": true]],
        ])

        XCTAssertTrue(MediaDownloadPolicy.metadataIndicatesDRM(metadata))
    }

    func testMediaDownloadPolicyRejectsWhenEveryFormatUsesDRM() throws {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "formats": [
                ["format_id": "video", "has_drm": true],
                ["format_id": "audio", "has_drm": true],
            ],
        ])

        XCTAssertTrue(MediaDownloadPolicy.metadataIndicatesDRM(metadata))
    }

    func testMediaDownloadPolicyAllowsAnyClearFormat() throws {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "formats": [
                ["format_id": "encrypted", "has_drm": true],
                ["format_id": "clear", "has_drm": false],
            ],
        ])

        XCTAssertFalse(MediaDownloadPolicy.metadataIndicatesDRM(metadata))
    }

    func testMediaDownloadPolicyFindsJSONAfterDiagnosticOutput() throws {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "formats": [["format_id": "clear"]],
        ])
        let output = Data("diagnostic\n".utf8) + metadata

        XCTAssertFalse(MediaDownloadPolicy.metadataIndicatesDRM(output))
        XCTAssertEqual(MediaDownloadPolicy.decision(for: output), .allow)
    }

    func testMediaDownloadPolicyRejectsUnverifiedMetadata() {
        XCTAssertEqual(
            MediaDownloadPolicy.decision(for: Data("not-json".utf8)),
            .rejectUnverified
        )
        XCTAssertEqual(
            MediaDownloadPolicy.decision(for: Data("{}".utf8)),
            .rejectUnverified
        )
    }

    func testPlaybackRateDefaultsToEightTimes() {
        XCTAssertEqual(YouTubeAdPlaybackPolicy.adPlaybackRate, 8)
        XCTAssertTrue(
            YouTubeAdPlaybackPolicy.javaScript.contains("const targetPlaybackRate = 8.0;")
        )
    }

    func testPolicySupportsYouTubeHosts() {
        XCTAssertTrue(YouTubeAdPlaybackPolicy.supports(host: "youtube.com"))
        XCTAssertTrue(YouTubeAdPlaybackPolicy.supports(host: "www.youtube.com"))
        XCTAssertTrue(YouTubeAdPlaybackPolicy.supports(host: "music.youtube.com"))
        XCTAssertTrue(YouTubeAdPlaybackPolicy.supports(host: "www.youtube-nocookie.com"))
        XCTAssertTrue(YouTubeAdPlaybackPolicy.supports(host: "WWW.YOUTUBE.COM."))
    }

    func testPolicyRejectsLookalikeAndUnrelatedHosts() {
        XCTAssertFalse(YouTubeAdPlaybackPolicy.supports(host: "youtube.com.example.org"))
        XCTAssertFalse(YouTubeAdPlaybackPolicy.supports(host: "notyoutube.com"))
        XCTAssertFalse(YouTubeAdPlaybackPolicy.supports(host: "example.com"))
        XCTAssertFalse(YouTubeAdPlaybackPolicy.supports(host: nil))
    }

    func testInjectedControllerAcceleratesAdsAndRestoresContentRate() throws {
        let context = try XCTUnwrap(JSContext())
        var scriptException: JSValue?
        context.exceptionHandler = { _, exception in
            scriptException = exception
        }
        context.evaluateScript(
            """
            const testMedia = { playbackRate: 1, defaultPlaybackRate: 1 };
            const testClasses = new Set();
            const testPlayer = {
              classList: { contains: (name) => testClasses.has(name) }
            };
            globalThis.window = globalThis;
            globalThis.location = { hostname: 'www.youtube.com' };
            globalThis.document = {
              documentElement: {},
              addEventListener() {},
              getElementById(id) { return id === 'movie_player' ? testPlayer : null; },
              querySelector(selector) {
                if (selector === '.html5-main-video' || selector === 'video') return testMedia;
                if (selector === '.html5-video-player') return testPlayer;
                return null;
              }
            };
            globalThis.MutationObserver = function (callback) {
              this.observe = function () { globalThis.testMutationCallback = callback; };
            };
            window.setInterval = function (callback) {
              globalThis.testIntervalCallback = callback;
              return 1;
            };
            globalThis.testMedia = testMedia;
            globalThis.testClasses = testClasses;
            """,
            withSourceURL: nil
        )
        context.evaluateScript(YouTubeAdPlaybackPolicy.javaScript, withSourceURL: nil)
        XCTAssertNil(scriptException?.toString())

        context.evaluateScript("testMedia.playbackRate = 1.5; testIntervalCallback();")
        context.evaluateScript("testClasses.add('ad-showing'); testMutationCallback();")

        let adRate = context.evaluateScript("testMedia.playbackRate")?.toDouble()
        XCTAssertEqual(adRate, 8)

        context.evaluateScript("testClasses.delete('ad-showing'); testMutationCallback();")

        let restoredRate = context.evaluateScript("testMedia.playbackRate")?.toDouble()
        XCTAssertEqual(restoredRate, 1.5)
        XCTAssertNil(scriptException?.toString())
    }
}
