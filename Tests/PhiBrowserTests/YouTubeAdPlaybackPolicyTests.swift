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

    func testMediaDownloadPolicyExtractsToolFailure() {
        let output = Data(
            "warning\nERROR: [youtube] example: Sign in to confirm you are not a bot\n".utf8
        )

        XCTAssertEqual(
            MediaDownloadPolicy.failureSummary(in: output),
            "[youtube] example: Sign in to confirm you are not a bot"
        )
    }

    func testMediaDownloadFormatPolicyUsesBestMergedVideoByDefault() {
        let ffmpegDirectory = URL(fileURLWithPath: "/tmp/ffmpeg")

        XCTAssertEqual(
            MediaDownloadFormatPolicy.arguments(
                kind: .video,
                quality: .best,
                ffmpegDirectory: ffmpegDirectory
            ),
            [
                "--ffmpeg-location", "/tmp/ffmpeg",
                "--format", "bv*+ba/b",
                "--merge-output-format", "mp4",
            ]
        )
    }

    func testMediaDownloadFormatPolicyLimitsMergedVideoHeight() {
        let arguments = MediaDownloadFormatPolicy.arguments(
            kind: .video,
            quality: .p1080,
            ffmpegDirectory: URL(fileURLWithPath: "/tmp/ffmpeg")
        )

        XCTAssertTrue(arguments.contains("bv*[height<=1080]+ba/b[height<=1080]"))
    }

    func testMediaDownloadFormatPolicyLimitsSingleFileVideoHeight() {
        XCTAssertEqual(
            MediaDownloadFormatPolicy.arguments(
                kind: .video,
                quality: .p720,
                ffmpegDirectory: nil
            ),
            ["--format", "b[ext=mp4][height<=720]/b[height<=720]"]
        )
    }

    func testMediaDownloadFormatPolicyKeepsAudioIndependentFromVideoQuality() {
        XCTAssertEqual(
            MediaDownloadFormatPolicy.arguments(
                kind: .audio,
                quality: .p360,
                ffmpegDirectory: URL(fileURLWithPath: "/tmp/ffmpeg")
            ),
            ["--format", "ba[ext=m4a]/ba/b"]
        )
    }

    func testMediaDownloadProgressPolicyParsesLiveToolOutput() throws {
        let progress = try XCTUnwrap(
            MediaDownloadProgressPolicy.parse(
                "__ASTRA_PROGRESS__:4193280:11829048:2403078.150274201"
            )
        )

        XCTAssertEqual(progress.receivedBytes, 4_193_280)
        XCTAssertEqual(progress.totalBytes, 11_829_048)
        XCTAssertEqual(progress.speed, 2_403_078)
    }

    func testMediaDownloadProgressPolicyTreatsUnavailableSpeedAsZero() throws {
        let progress = try XCTUnwrap(
            MediaDownloadProgressPolicy.parse("__ASTRA_PROGRESS__:1024:11829048:NA")
        )

        XCTAssertEqual(progress.receivedBytes, 1_024)
        XCTAssertEqual(progress.totalBytes, 11_829_048)
        XCTAssertEqual(progress.speed, 0)
    }

    func testMediaDownloadSourcePolicyCanonicalizesYouTubeShorts() throws {
        let pageURL = try XCTUnwrap(
            URL(string: "https://www.youtube.com/shorts/abc123?feature=share")
        )
        let canonicalURL = MediaDownloadSourcePolicy.canonicalPageURL(pageURL)

        XCTAssertEqual(canonicalURL.absoluteString, "https://www.youtube.com/watch?v=abc123")
    }

    func testMediaDownloadSourcePolicyPrefersCanonicalShortsPageOverTemporaryStream() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://youtube.com/shorts/abc123"))
        let canonicalURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123"))
        let streamURL = try XCTUnwrap(URL(string: "https://rr.example.googlevideo.com/videoplayback"))
        let candidate = MediaDownloadCandidate(
            url: streamURL,
            title: "Short video",
            kind: .video,
            durationSeconds: 20
        )

        XCTAssertEqual(
            MediaDownloadSourcePolicy.orderedSourceURLs(
                pageURL: pageURL,
                selectedCandidate: candidate
            ),
            [
                canonicalURL,
                streamURL,
                pageURL,
            ]
        )
    }

    func testMediaDownloadSourcePolicyPreservesCandidateFirstForFeedPages() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://x.com/home"))
        let postURL = try XCTUnwrap(URL(string: "https://x.com/user/status/123"))
        let candidate = MediaDownloadCandidate(
            url: postURL,
            title: "Post with video",
            kind: .video,
            durationSeconds: 42
        )

        XCTAssertEqual(
            MediaDownloadSourcePolicy.orderedSourceURLs(
                pageURL: pageURL,
                selectedCandidate: candidate
            ),
            [postURL, pageURL]
        )
    }

    func testMediaDownloadSourcePolicyCollectsCookiesForPageAndEverySource() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://youtube.com/shorts/abc123"))
        let canonicalURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123"))
        let streamURL = try XCTUnwrap(URL(string: "https://rr.example.googlevideo.com/videoplayback"))

        XCTAssertEqual(
            MediaDownloadSourcePolicy.cookieSourceURLs(
                pageURL: pageURL,
                sourceURLs: [canonicalURL, streamURL, pageURL]
            ),
            [pageURL, canonicalURL, streamURL]
        )
    }

    func testMediaDownloadCandidateDecodesPageDescriptor() throws {
        let data = Data(
            #"[{"url":"https://x.com/user/status/123","title":"Post with video","kind":"video","durationSeconds":42.5}]"#.utf8
        )

        let candidate = try XCTUnwrap(
            JSONDecoder().decode([MediaDownloadCandidate].self, from: data).first
        )
        XCTAssertEqual(candidate.url.absoluteString, "https://x.com/user/status/123")
        XCTAssertEqual(candidate.title, "Post with video")
        XCTAssertEqual(candidate.kind, .video)
        XCTAssertEqual(candidate.durationSeconds, 42.5)
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
