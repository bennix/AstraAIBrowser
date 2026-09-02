// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

/// Actions the webpage context menu offers for the current text selection.
enum WebSelectionAction: Int, CaseIterable {
    case translate
    case lookUpWord
    case addToVocabulary

    var contextMenuTitle: String {
        switch self {
        case .translate:
            return NSLocalizedString(
                "translation.selection.contextMenuAction",
                value: "Translate Selection",
                comment: "Webpage context menu - Action that translates the currently selected text"
            )
        case .lookUpWord:
            return NSLocalizedString(
                "vocabulary.selection.lookUpContextMenuAction",
                value: "Look Up Word",
                comment: "Webpage context menu - Action that shows the dictionary meaning of the selected word"
            )
        case .addToVocabulary:
            return NSLocalizedString(
                "vocabulary.selection.addContextMenuAction",
                value: "Add to Vocabulary Book",
                comment: "Webpage context menu - Action that looks up the selected word and saves it to the vocabulary book"
            )
        }
    }
}

/// Dictionary-style result for a single selected word or short phrase.
struct VocabularyWordLookup: Codable, Equatable, Sendable {
    let word: String
    let partOfSpeech: String
    let translation: String
}

struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let word: String
    let partOfSpeech: String
    let translation: String
    let targetLanguage: String
    let sourceURL: String?
    let createdAt: Date
}

enum VocabularyLookupPolicy {
    static let maximumCharacterCount = 120

    /// Collapses internal whitespace so a selection that wraps across lines
    /// still reads as one term.
    static func normalizedWord(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum VocabularyBookMarkdownExporter {
    static func markdown(for entries: [VocabularyEntry], exportedAt: Date = Date()) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        dateFormatter.timeZone = .current
        var lines: [String] = []
        lines.append("# Vocabulary Book")
        lines.append("")
        lines.append("Exported \(dateFormatter.string(from: exportedAt)) · \(entries.count) words")
        lines.append("")
        lines.append("| Word | Part of Speech | Translation | Added |")
        lines.append("| --- | --- | --- | --- |")
        for entry in entries {
            lines.append(
                "| \(cell(entry.word)) | \(cell(entry.partOfSpeech)) | \(cell(entry.translation)) | \(dateFormatter.string(from: entry.createdAt)) |"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func cell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Persistent, app-wide list of saved words. Entries are stored newest first.
@MainActor
final class VocabularyBookStore: ObservableObject {
    static let shared = VocabularyBookStore(fileURL: defaultFileURL)

    private static var defaultFileURL: URL {
        URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory())
            .appendingPathComponent("VocabularyBook.json")
    }

    @Published private(set) var entries: [VocabularyEntry] = []

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = Self.load(from: fileURL)
    }

    func contains(word: String) -> Bool {
        let key = Self.dedupeKey(word)
        return entries.contains { Self.dedupeKey($0.word) == key }
    }

    /// Saves a lookup. Returns the stored entry and whether it was newly
    /// added; an existing entry for the same word is returned unchanged.
    @discardableResult
    func add(
        _ lookup: VocabularyWordLookup,
        targetLanguage: String,
        sourceURL: String?
    ) -> (entry: VocabularyEntry, isNew: Bool) {
        let key = Self.dedupeKey(lookup.word)
        if let existing = entries.first(where: { Self.dedupeKey($0.word) == key }) {
            return (existing, false)
        }
        let entry = VocabularyEntry(
            id: UUID(),
            word: lookup.word,
            partOfSpeech: lookup.partOfSpeech,
            translation: lookup.translation,
            targetLanguage: targetLanguage,
            sourceURL: sourceURL,
            createdAt: Date()
        )
        entries.insert(entry, at: 0)
        save()
        return (entry, true)
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    func markdown() -> String {
        VocabularyBookMarkdownExporter.markdown(for: entries)
    }

    private static func dedupeKey(_ word: String) -> String {
        VocabularyLookupPolicy.normalizedWord(word).lowercased()
    }

    private static func load(from url: URL) -> [VocabularyEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([VocabularyEntry].self, from: data)
        } catch {
            AppLogWarn("[VocabularyBook] failed to load entries error=\(String(describing: error))")
            return []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            AppLogWarn("[VocabularyBook] failed to save entries error=\(String(describing: error))")
        }
    }
}

enum VocabularyLookupError: LocalizedError {
    case selectionTooLong

    var errorDescription: String? {
        switch self {
        case .selectionTooLong:
            return NSLocalizedString(
                "vocabulary.error.selectionTooLong",
                value: "Select a single word or a short phrase to look it up.",
                comment: "Word lookup - Error shown when the selected text is too long to be treated as a dictionary entry"
            )
        }
    }
}

extension BrowserState {
    @MainActor
    func handleWebSelectionAction(_ action: WebSelectionAction, text: String, in tab: Tab) {
        switch action {
        case .translate:
            translateSelectedText(text, in: tab)
        case .lookUpWord:
            lookUpSelectedWord(text, in: tab, savesToVocabulary: false)
        case .addToVocabulary:
            lookUpSelectedWord(text, in: tab, savesToVocabulary: true)
        }
    }

    /// Looks up the selected word with the configured translation engine.
    /// Shows the result in a floating lookup card, or stores it directly in
    /// the vocabulary book when `savesToVocabulary` is set.
    @MainActor
    func lookUpSelectedWord(_ text: String, in tab: Tab, savesToVocabulary: Bool) {
        let word = VocabularyLookupPolicy.normalizedWord(text)
        guard !word.isEmpty else {
            NSSound.beep()
            return
        }
        guard word.count <= VocabularyLookupPolicy.maximumCharacterCount else {
            OverlayToastCenter.shared.show(
                title: Self.lookupFailedTitle,
                message: VocabularyLookupError.selectionTooLong.localizedDescription,
                duration: 6,
                in: self
            )
            return
        }

        let language = ImmersiveTranslationPreferences.loadLanguage()
        let provider = ImmersiveTranslationPreferences.loadProvider()
        let pageURL = tab.url
        let store = VocabularyBookStore.shared

        tab.wordLookupTask?.cancel()
        let operationID = UUID()
        tab.wordLookupOperationID = operationID
        AppLogInfo(
            "[WordLookup] started characters=\(word.count) savesToVocabulary=\(savesToVocabulary) window=\(windowId)"
        )

        if savesToVocabulary {
            OverlayToastCenter.shared.show(
                title: NSLocalizedString(
                    "vocabulary.selection.addProgressTitle",
                    value: "Adding to Vocabulary Book…",
                    comment: "Vocabulary book - Brief toast shown while the selected word is being looked up before saving"
                ),
                duration: 1.2,
                in: self
            )
        } else {
            SelectionCardController.shared.presentLookingUp(word: word, language: language)
        }

        tab.wordLookupTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.wordLookupOperationID == operationID {
                    tab.wordLookupTask = nil
                    tab.wordLookupOperationID = nil
                }
            }
            do {
                let lookup = try await self.lookUpWord(word, language: language, provider: provider)
                try Task.checkCancellation()
                AppLogInfo(
                    "[WordLookup] completed partOfSpeech=\(lookup.partOfSpeech) sameOperation=\(tab.wordLookupOperationID == operationID) tabAlive=\(self.tabs.contains(where: { $0 === tab }))"
                )
                guard tab.wordLookupOperationID == operationID,
                      self.tabs.contains(where: { $0 === tab }) else { return }

                if savesToVocabulary {
                    let result = store.add(lookup, targetLanguage: language.rawValue, sourceURL: pageURL)
                    OverlayToastCenter.shared.show(
                        title: result.isNew ? Self.addedToVocabularyTitle : Self.alreadyInVocabularyTitle,
                        message: Self.summary(for: result.entry),
                        duration: 5,
                        in: self
                    )
                } else {
                    SelectionCardController.shared.presentLookup(
                        lookup,
                        language: language,
                        isSaved: store.contains(word: lookup.word),
                        onAdd: { [weak self] in
                            let result = store.add(lookup, targetLanguage: language.rawValue, sourceURL: pageURL)
                            guard let self else { return }
                            OverlayToastCenter.shared.show(
                                title: result.isNew ? Self.addedToVocabularyTitle : Self.alreadyInVocabularyTitle,
                                message: Self.summary(for: result.entry),
                                duration: 4,
                                in: self
                            )
                        }
                    )
                }
            } catch {
                AppLogInfo(
                    "[WordLookup] failed error=\(String(describing: error)) cancelled=\(Task.isCancelled)"
                )
                guard !Task.isCancelled,
                      tab.wordLookupOperationID == operationID else { return }
                if savesToVocabulary {
                    OverlayToastCenter.shared.show(
                        title: Self.lookupFailedTitle,
                        message: error.localizedDescription,
                        duration: 6,
                        in: self
                    )
                } else {
                    SelectionCardController.shared.presentFailure(
                        title: Self.lookupFailedTitle,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    @MainActor
    private func lookUpWord(
        _ word: String,
        language: ImmersiveTranslationLanguage,
        provider: ImmersiveTranslationProvider
    ) async throws -> VocabularyWordLookup {
        switch provider {
        case .zenMux:
            guard let apiKey = try ZenMuxCredentialStore.shared.loadAPIKey(),
                  !apiKey.isEmpty else {
                throw ImmersiveTranslationError.missingZenMuxCredential
            }
            return try await APIClient.shared.lookUpVocabularyWord(
                word,
                to: language,
                apiKey: apiKey,
                model: PhiPreferences.AISettings.loadZenMuxModel()
            )
        }
    }

    static func summary(for entry: VocabularyEntry) -> String {
        var parts = [entry.word]
        if !entry.partOfSpeech.isEmpty {
            parts.append(entry.partOfSpeech)
        }
        parts.append(entry.translation)
        return parts.joined(separator: " · ")
    }

    private static var lookupFailedTitle: String {
        NSLocalizedString(
            "vocabulary.selection.lookUpFailedTitle",
            value: "Word lookup failed",
            comment: "Word lookup - Toast title shown when the selected word could not be looked up"
        )
    }

    private static var addedToVocabularyTitle: String {
        NSLocalizedString(
            "vocabulary.selection.addedTitle",
            value: "Added to Vocabulary Book",
            comment: "Vocabulary book - Toast title shown after a word was saved"
        )
    }

    private static var alreadyInVocabularyTitle: String {
        NSLocalizedString(
            "vocabulary.selection.alreadySavedTitle",
            value: "Already in Vocabulary Book",
            comment: "Vocabulary book - Toast title shown when the word had been saved earlier"
        )
    }
}
