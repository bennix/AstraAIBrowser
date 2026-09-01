// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class VocabularyBookTests: XCTestCase {
    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabularyBookTests-\(UUID().uuidString)")
            .appendingPathComponent("VocabularyBook.json")
    }

    @MainActor
    func testAddDeduplicatesByWordAndPersistsAcrossReload() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = VocabularyBookStore(fileURL: fileURL)
        let lookup = VocabularyWordLookup(word: "Ephemeral", partOfSpeech: "adjective", translation: "éphémère")

        let first = store.add(lookup, targetLanguage: "fr", sourceURL: "https://example.com")
        let second = store.add(
            VocabularyWordLookup(word: "ephemeral", partOfSpeech: "adjective", translation: "passager"),
            targetLanguage: "fr",
            sourceURL: nil
        )

        XCTAssertTrue(first.isNew)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.entry, first.entry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.contains(word: " EPHEMERAL "))

        let reloaded = VocabularyBookStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.map(\.id), store.entries.map(\.id))
        XCTAssertEqual(reloaded.entries.first?.word, "Ephemeral")
        XCTAssertEqual(reloaded.entries.first?.partOfSpeech, "adjective")
        XCTAssertEqual(reloaded.entries.first?.translation, "éphémère")
        XCTAssertEqual(reloaded.entries.first?.sourceURL, "https://example.com")

        reloaded.remove(ids: [first.entry.id])
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertTrue(VocabularyBookStore(fileURL: fileURL).entries.isEmpty)
    }

    func testMarkdownExportProducesTableWithEscapedCells() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T10:00:00Z"))
        let entries = [
            VocabularyEntry(
                id: UUID(),
                word: "pipe|line",
                partOfSpeech: "noun",
                translation: "conduite\ncanalisation",
                targetLanguage: "fr",
                sourceURL: nil,
                createdAt: createdAt
            ),
        ]

        let markdown = VocabularyBookMarkdownExporter.markdown(for: entries, exportedAt: createdAt)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.first, "# Vocabulary Book")
        XCTAssertTrue(lines.contains("| Word | Part of Speech | Translation | Added |"))
        XCTAssertTrue(lines.contains("| --- | --- | --- | --- |"))
        XCTAssertTrue(lines.contains("| pipe\\|line | noun | conduite canalisation | 2026-09-01 |"))
    }

    func testLookupDecodingExtractsObjectAndFallsBackToRequestedWord() throws {
        let content = """
        Sure, here is the entry:
        ```json
        {"word": "", "partOfSpeech": "Noun", "translation": "pomme; pommier"}
        ```
        """

        let lookup = try APIClient.decodeVocabularyWordLookup(from: content, requestedWord: "apples")

        XCTAssertEqual(lookup, VocabularyWordLookup(word: "apples", partOfSpeech: "noun", translation: "pomme; pommier"))
        XCTAssertThrowsError(
            try APIClient.decodeVocabularyWordLookup(from: "{\"word\": \"apple\"}", requestedWord: "apple")
        )
    }

    @MainActor
    func testSelectionActionsMapToDistinctContextMenuCommands() {
        let ids = WebSelectionAction.allCases.map(CefWebContentWrapper.contextMenuCommandID(for:))
        XCTAssertEqual(Set(ids).count, WebSelectionAction.allCases.count)
        for action in WebSelectionAction.allCases {
            XCTAssertEqual(
                CefWebContentWrapper.selectionAction(
                    forContextMenuCommandID: CefWebContentWrapper.contextMenuCommandID(for: action)
                ),
                action
            )
        }
        XCTAssertNil(CefWebContentWrapper.selectionAction(forContextMenuCommandID: ids.min()! - 1))
        XCTAssertEqual(VocabularyLookupPolicy.normalizedWord("  take \n  off "), "take off")
    }
}
