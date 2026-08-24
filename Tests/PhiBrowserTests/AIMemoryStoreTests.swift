// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CefKit
import Foundation
import XCTest
@testable import Phi

final class AIMemoryStoreTests: XCTestCase {
    private var storageDirectory: URL!

    override func setUpWithError() throws {
        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let storageDirectory,
           storageDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        storageDirectory = nil
    }

    func testMemorySchemeSupportsSameOriginFetch() {
        let options = AstraMemorySchemeHandler.customScheme.options

        XCTAssertTrue(options.contains(.standard))
        XCTAssertTrue(options.contains(.secure))
        XCTAssertTrue(options.contains(.corsEnabled))
        XCTAssertTrue(options.contains(.fetchEnabled))
        XCTAssertFalse(options.contains(.local))
        XCTAssertFalse(options.contains(.displayIsolated))
    }

    func testPersistsAndRetrievesRelevantVectors() async throws {
        let store = AIMemoryStore()
        let concise = try await store.add(
            "I prefer concise answers with a summary first.",
            storageDirectory: storageDirectory
        )
        _ = try await store.add(
            "My favorite hiking area is around Mount Takao.",
            storageDirectory: storageDirectory
        )

        let matches = try await store.search(
            query: "Please remember my concise answer preference.",
            storageDirectory: storageDirectory
        )
        XCTAssertEqual(matches.first?.record.id, concise.id)
        XCTAssertEqual(matches.first?.record.source, .manual)

        let reopenedStore = AIMemoryStore()
        let persisted = try await reopenedStore.list(storageDirectory: storageDirectory)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AIMemoryStore.databaseURL(storageDirectory: storageDirectory).path
        ))
        let notes = AIMemoryStore.vaultURL(storageDirectory: storageDirectory)
            .appendingPathComponent("Notes", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: notes.path)
                .filter { $0.hasSuffix(".md") }
                .count,
            2
        )
    }

    func testMultilingualVectorSearchAndDeletion() async throws {
        let store = AIMemoryStore()
        let chinese = try await store.add(
            "\u{4E2D}\u{6587}\u{56DE}\u{7B54}\u{8981}\u{7B80}\u{6D01}",
            storageDirectory: storageDirectory
        )
        _ = try await store.add(
            "Use dark mode for development tools.",
            storageDirectory: storageDirectory
        )

        let matches = try await store.search(
            query: "\u{4E2D}\u{6587}\u{56DE}\u{7B54}\u{504F}\u{597D}",
            storageDirectory: storageDirectory
        )
        XCTAssertEqual(matches.first?.record.id, chinese.id)

        let deleted = try await store.delete(
            id: chinese.id,
            storageDirectory: storageDirectory
        )
        XCTAssertTrue(deleted)
        let remaining = try await store.list(storageDirectory: storageDirectory)
        XCTAssertEqual(remaining.count, 1)
        try await store.deleteAll(storageDirectory: storageDirectory)
        let empty = try await store.list(storageDirectory: storageDirectory)
        XCTAssertTrue(empty.isEmpty)
    }

    func testRejectsEmptyAndOversizedMemory() async throws {
        let store = AIMemoryStore()
        do {
            _ = try await store.add("   ", storageDirectory: storageDirectory)
            XCTFail("Expected empty text to be rejected")
        } catch AIMemoryStoreError.emptyText {
        }

        do {
            _ = try await store.add(
                String(repeating: "a", count: AIMemoryStore.maximumTextLength + 1),
                storageDirectory: storageDirectory
            )
            XCTFail("Expected oversized text to be rejected")
        } catch AIMemoryStoreError.textTooLong {
        }
    }

    func testExpiredConversationRequiresSummaryBeforeDeletion() async throws {
        let store = AIMemoryStore()
        let oldDate = Date().addingTimeInterval(-100 * 24 * 60 * 60)
        let oldConversation = try await store.add(
            "Conversation\nUser: Remember this project.\nAssistant: The project uses Swift.",
            source: .conversation,
            now: oldDate,
            storageDirectory: storageDirectory
        )
        let manual = try await store.add(
            "This manual memory must not expire.",
            now: oldDate,
            storageDirectory: storageDirectory
        )

        let batch = try await store.conversationCompactionBatch(
            storageDirectory: storageDirectory,
            expiredBefore: Date().addingTimeInterval(-90 * 24 * 60 * 60)
        )
        XCTAssertEqual(batch.map(\.id), [oldConversation.id])

        _ = try await store.add(
            "Long-term conversation summary\nThe project uses Swift.",
            source: .summary,
            storageDirectory: storageDirectory
        )
        try await store.delete(
            ids: batch.map(\.id),
            storageDirectory: storageDirectory
        )

        let records = try await store.list(storageDirectory: storageDirectory)
        XCTAssertTrue(records.contains(where: { $0.id == manual.id }))
        XCTAssertTrue(records.contains(where: { $0.source == .summary }))
        XCTAssertFalse(records.contains(where: { $0.id == oldConversation.id }))
    }
}
