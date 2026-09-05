// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

struct ImmersiveTranslationSegment: Codable, Equatable, Sendable {
    let id: String
    let text: String
}

struct ImmersiveTranslationPageSnapshot: Equatable, Sendable {
    let sessionID: String
    let segments: [ImmersiveTranslationSegment]
}

enum ImmersiveTranslationBatchPlanner {
    static let maximumSegmentCount = 16
    static let maximumCharacterCount = 6_000
    static let maximumConcurrentBatchCount = 4

    static func batches(
        for segments: [ImmersiveTranslationSegment],
        maximumSegmentCount: Int = maximumSegmentCount,
        maximumCharacterCount: Int = maximumCharacterCount
    ) -> [[ImmersiveTranslationSegment]] {
        guard maximumSegmentCount > 0, maximumCharacterCount > 0 else { return [] }

        var result: [[ImmersiveTranslationSegment]] = []
        var batch: [ImmersiveTranslationSegment] = []
        var characterCount = 0
        for segment in segments {
            if !batch.isEmpty,
               (batch.count >= maximumSegmentCount
                    || characterCount + segment.text.count > maximumCharacterCount) {
                result.append(batch)
                batch.removeAll(keepingCapacity: true)
                characterCount = 0
            }
            batch.append(segment)
            characterCount += segment.text.count
        }
        if !batch.isEmpty {
            result.append(batch)
        }
        return result
    }
}

struct ImmersiveTranslationWritebackProgress {
    private(set) var completedTranslations: [ImmersiveTranslationSegment] = []

    mutating func record(
        _ translations: [ImmersiveTranslationSegment]
    ) -> [ImmersiveTranslationSegment] {
        completedTranslations.append(contentsOf: translations)
        return translations
    }
}

enum SelectionTranslationPolicy {
    static let maximumCharacterCount = 6_000

    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ImmersiveTranslationLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case italian = "it"
    case dutch = "nl"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case indonesian = "id"
    case thai = "th"
    case vietnamese = "vi"
    case turkish = "tr"

    var id: String { rawValue }

    var displayName: String {
        let locale = Locale(identifier: rawValue)
        return locale.localizedString(forIdentifier: rawValue)?.capitalized(with: locale)
            ?? rawValue
    }
}

enum ImmersiveTranslationProvider: String, CaseIterable, Identifiable {
    case zenMux = "zenmux"

    var id: String { rawValue }

    var displayName: String {
        NSLocalizedString(
            "translation.provider.zenMux",
            value: "ZenMux enhanced",
            comment: "Immersive translation - ZenMux provider name"
        )
    }
}

enum ImmersiveTranslationState: Equatable {
    case inactive
    case translating
    case active(language: ImmersiveTranslationLanguage, provider: ImmersiveTranslationProvider)
    case failed(String)
}

enum ImmersiveTranslationPreferences {
    static let automaticDisplayKey = "immersiveTranslation.automaticDisplay"
    static var automaticDisplayEnabled: Bool {
        automaticDisplayEnabled(from: .standard)
    }
    static func automaticDisplayEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticDisplayKey) == nil
            || defaults.bool(forKey: automaticDisplayKey)
    }
    private static let languageKey = "immersiveTranslation.targetLanguage"
    private static let displayLanguagesKey = "immersiveTranslation.displayLanguages"
    private static let providerKey = "immersiveTranslation.provider"

    static func loadDisplayLanguages(from defaults: UserDefaults = .standard) -> [ImmersiveTranslationLanguage] {
        if let stored = defaults.stringArray(forKey: displayLanguagesKey) {
            let languages = normalizedDisplayLanguages(stored.compactMap(ImmersiveTranslationLanguage.init(rawValue:)))
            return languages
        }
        // Preserve the previous single-language preference until an ordered list is saved.
        if let stored = defaults.string(forKey: languageKey),
           let language = ImmersiveTranslationLanguage(rawValue: stored) {
            return language == .simplifiedChinese ? [.simplifiedChinese, .english] : [language]
        }
        return [.simplifiedChinese, .english]
    }

    static func saveDisplayLanguages(
        _ languages: [ImmersiveTranslationLanguage],
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(normalizedDisplayLanguages(languages).map(\.rawValue), forKey: displayLanguagesKey)
    }

    private static func normalizedDisplayLanguages(
        _ languages: [ImmersiveTranslationLanguage]
    ) -> [ImmersiveTranslationLanguage] {
        var unique: [ImmersiveTranslationLanguage] = []
        for language in languages where !unique.contains(language) { unique.append(language) }
        return unique.isEmpty ? [.simplifiedChinese, .english] : unique
    }

    static func loadLanguage(from defaults: UserDefaults = .standard) -> ImmersiveTranslationLanguage {
        defaults.string(forKey: languageKey)
            .flatMap(ImmersiveTranslationLanguage.init(rawValue:))
            ?? .simplifiedChinese
    }

    static func saveLanguage(
        _ language: ImmersiveTranslationLanguage,
        to defaults: UserDefaults = .standard
    ) {
        if defaults.object(forKey: displayLanguagesKey) == nil {
            saveDisplayLanguages(loadDisplayLanguages(from: defaults), to: defaults)
        }
        defaults.set(language.rawValue, forKey: languageKey)
    }

    static func loadProvider(from defaults: UserDefaults = .standard) -> ImmersiveTranslationProvider {
        defaults.string(forKey: providerKey)
            .flatMap(ImmersiveTranslationProvider.init(rawValue:))
            ?? .zenMux
    }

    static func saveProvider(
        _ provider: ImmersiveTranslationProvider,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(provider.rawValue, forKey: providerKey)
    }
}

enum ImmersiveTranslationError: LocalizedError {
    case unsupportedPage
    case emptyPage
    case missingZenMuxCredential
    case pageChanged
    case selectionTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedPage:
            return NSLocalizedString(
                "translation.error.unsupportedPage",
                value: "This page cannot be translated.",
                comment: "Immersive translation - Unsupported page error"
            )
        case .emptyPage:
            return NSLocalizedString(
                "translation.error.emptyPage",
                value: "No readable text was found on this page.",
                comment: "Immersive translation - Empty page error"
            )
        case .missingZenMuxCredential:
            return NSLocalizedString(
                "translation.error.missingZenMuxCredential",
                value: "Add a ZenMux API key in AI Settings before using enhanced translation.",
                comment: "Immersive translation - Missing ZenMux credential error"
            )
        case .pageChanged:
            return NSLocalizedString(
                "translation.error.pageChanged",
                value: "The page changed before translation finished. Try again.",
                comment: "Immersive translation - Navigation occurred during translation error"
            )
        case .selectionTooLong:
            return NSLocalizedString(
                "translation.error.selectionTooLong",
                value: "The selection is too long. Select a shorter passage or translate the full page instead.",
                comment: "Selection translation - Error shown when selected webpage text exceeds the supported length"
            )
        }
    }
}

extension BrowserState {
    @MainActor
    func translateFocusedPageAutomatically() {
        guard ImmersiveTranslationPreferences.automaticDisplayEnabled,
              !AgentSpaceManager.shared.isAgentSpace(spaceId),
              let tab = focusingTab, !tab.isLoading,
              Self.shouldOfferImmersiveTranslation(pageURL: tab.url, isIncognito: isIncognito,
                                                   isOverviewActive: groupOverviewState != nil),
              tab.immersiveTranslationState == .inactive,
              !tab.automaticTranslationSuppressed else { return }
        toggleImmersiveTranslation(
            language: ImmersiveTranslationPreferences.loadDisplayLanguages()[0],
            provider: .zenMux,
            translatedOnly: true
        )
    }

    static func shouldOfferImmersiveTranslation(
        pageURL: String?,
        isIncognito: Bool,
        isOverviewActive: Bool
    ) -> Bool {
        guard !isIncognito,
              !isOverviewActive,
              let pageURL,
              let scheme = URL(string: pageURL)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    @MainActor
    private func translateImmersiveBatch(
        _ segments: [ImmersiveTranslationSegment],
        language: ImmersiveTranslationLanguage,
        provider: ImmersiveTranslationProvider
    ) async throws -> [ImmersiveTranslationSegment] {
        switch provider {
        case .zenMux:
            guard let apiKey = try ZenMuxCredentialStore.shared.loadAPIKey(),
                  !apiKey.isEmpty else {
                throw ImmersiveTranslationError.missingZenMuxCredential
            }
            return try await APIClient.shared.translateImmersiveSegments(
                segments,
                to: language,
                apiKey: apiKey,
                model: PhiPreferences.AISettings.loadZenMuxModel()
            )
        }
    }

    @MainActor
    func toggleImmersiveTranslation(
        language: ImmersiveTranslationLanguage,
        provider: ImmersiveTranslationProvider,
        translatedOnly: Bool? = nil
    ) {
        guard let tab = focusingTab,
              Self.shouldOfferImmersiveTranslation(
                pageURL: tab.url,
                isIncognito: isIncognito,
                isOverviewActive: groupOverviewState != nil
              ),
              let pageURL = tab.url,
              let content = tab.webContentWrapper as? ImmersiveTranslationProviding else {
            NSSound.beep()
            return
        }

        if case .active = tab.immersiveTranslationState {
            tab.automaticTranslationSuppressed = true
            Task { @MainActor in
                await content.removeImmersiveTranslations()
                guard tab.url == pageURL else { return }
                tab.immersiveTranslationState = .inactive
            }
            return
        }
        guard tab.immersiveTranslationState != .translating else { return }

        ImmersiveTranslationPreferences.saveLanguage(language)
        ImmersiveTranslationPreferences.saveProvider(provider)
        let translatedOnly = translatedOnly ?? ImmersiveTranslationPreferences.automaticDisplayEnabled
        let requestedLanguages = translatedOnly
            ? [language] + ImmersiveTranslationPreferences.loadDisplayLanguages().filter { $0 != language }
            : [language]
        tab.immersiveTranslationTask?.cancel()
        let operationID = UUID()
        tab.immersiveTranslationOperationID = operationID
        tab.immersiveTranslationState = .translating

        tab.immersiveTranslationTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.immersiveTranslationOperationID == operationID {
                    tab.immersiveTranslationTask = nil
                    tab.immersiveTranslationOperationID = nil
                }
            }
            do {
                AppLogInfo("[ImmersiveTranslation] operation started")
                let snapshot = try await content.immersiveTranslationSnapshot(translatedOnly: translatedOnly)
                try Task.checkCancellation()
                let segments = snapshot.segments
                guard !segments.isEmpty else { throw ImmersiveTranslationError.emptyPage }
                let batches = ImmersiveTranslationBatchPlanner.batches(for: segments)
                AppLogInfo(
                    "[ImmersiveTranslation] planned segments=\(segments.count) batches=\(batches.count)"
                )
                var writebackProgress = ImmersiveTranslationWritebackProgress()

                try await withThrowingTaskGroup(
                    of: (Int, [ImmersiveTranslationSegment]).self
                ) { group in
                    var nextBatchIndex = 0

                    func enqueueNextBatch(
                        _ group: inout ThrowingTaskGroup<(Int, [ImmersiveTranslationSegment]), Error>
                    ) {
                        guard nextBatchIndex < batches.count else { return }
                        let batchIndex = nextBatchIndex
                        let batch = batches[batchIndex]
                        nextBatchIndex += 1
                        AppLogInfo(
                            "[ImmersiveTranslation] batch started index=\(batchIndex + 1) requested=\(batch.count)"
                        )
                        group.addTask { @MainActor in
                            var lastError: Error = ImmersiveTranslationError.emptyPage
                            for requestedLanguage in requestedLanguages {
                                try Task.checkCancellation()
                                do {
                                    let translations = try await self.translateImmersiveBatch(
                                        batch, language: requestedLanguage, provider: provider
                                    )
                                    return (batchIndex, translations)
                                } catch {
                                    try Task.checkCancellation()
                                    guard !(error is ImmersiveTranslationError) else { throw error }
                                    lastError = error
                                }
                            }
                            throw lastError
                        }
                    }

                    for _ in 0..<ImmersiveTranslationBatchPlanner.maximumConcurrentBatchCount {
                        enqueueNextBatch(&group)
                    }

                    while let (batchIndex, translations) = try await group.next() {
                        enqueueNextBatch(&group)
                        AppLogInfo(
                            "[ImmersiveTranslation] batch translated index=\(batchIndex + 1) returned=\(translations.count)"
                        )
                        guard translations.map(\.id) == batches[batchIndex].map(\.id) else {
                            throw ImmersiveTranslationError.pageChanged
                        }
                        let writebackTranslations = writebackProgress.record(translations)

                        try Task.checkCancellation()
                        guard tab.immersiveTranslationOperationID == operationID,
                              tab.webContentWrapper === content,
                              tab.immersiveTranslationState == .translating else {
                            group.cancelAll()
                            return
                        }
                        let applied = await content.applyImmersiveTranslations(
                            writebackTranslations,
                            targetLanguage: language.rawValue,
                            sessionID: snapshot.sessionID
                        )
                        try Task.checkCancellation()
                        guard tab.immersiveTranslationOperationID == operationID else {
                            group.cancelAll()
                            return
                        }
                        guard applied else { throw ImmersiveTranslationError.pageChanged }
                    }
                }

                try Task.checkCancellation()
                guard tab.immersiveTranslationOperationID == operationID,
                      tab.webContentWrapper === content else { return }
                _ = await content.applyImmersiveTranslations(
                    writebackProgress.completedTranslations,
                    targetLanguage: language.rawValue,
                    sessionID: snapshot.sessionID
                )

                tab.immersiveTranslationState = .active(language: language, provider: provider)
                AppLogInfo("[ImmersiveTranslation] operation completed")
            } catch {
                AppLogInfo(
                    "[ImmersiveTranslation] operation failed error=\(String(describing: error))"
                )
                guard !Task.isCancelled,
                      tab.immersiveTranslationOperationID == operationID,
                      tab.url == pageURL else { return }
                tab.immersiveTranslationState = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    func translateSelectedText(_ text: String, in tab: Tab) {
        let selection = SelectionTranslationPolicy.normalizedText(text)
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }

        let language = ImmersiveTranslationPreferences.loadLanguage()
        let provider = ImmersiveTranslationPreferences.loadProvider()
        guard selection.count <= SelectionTranslationPolicy.maximumCharacterCount else {
            SelectionCardController.shared.presentFailure(
                title: Self.selectionTranslationFailedTitle,
                message: ImmersiveTranslationError.selectionTooLong.localizedDescription
            )
            return
        }

        tab.selectionTranslationTask?.cancel()
        let operationID = UUID()
        let pageURL = tab.url
        tab.selectionTranslationOperationID = operationID
        AppLogInfo("[SelectionTranslation] started characters=\(selection.count) window=\(windowId)")
        SelectionCardController.shared.presentTranslating(original: selection, language: language)

        tab.selectionTranslationTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.selectionTranslationOperationID == operationID {
                    tab.selectionTranslationTask = nil
                    tab.selectionTranslationOperationID = nil
                }
            }
            do {
                let segment = ImmersiveTranslationSegment(
                    id: "selection-\(operationID.uuidString)",
                    text: selection
                )
                let translations = try await self.translateImmersiveBatch(
                    [segment],
                    language: language,
                    provider: provider
                )
                try Task.checkCancellation()
                AppLogInfo(
                    "[SelectionTranslation] completed returned=\(translations.count) sameOperation=\(tab.selectionTranslationOperationID == operationID) sameURL=\(tab.url == pageURL) tabAlive=\(self.tabs.contains(where: { $0 === tab }))"
                )
                guard tab.selectionTranslationOperationID == operationID,
                      tab.url == pageURL,
                      self.tabs.contains(where: { $0 === tab }),
                      let translation = translations.first,
                      translation.id == segment.id else { return }
                SelectionCardController.shared.presentTranslation(
                    original: selection,
                    translated: translation.text,
                    language: language
                )
            } catch {
                AppLogInfo(
                    "[SelectionTranslation] failed error=\(String(describing: error)) cancelled=\(Task.isCancelled)"
                )
                guard !Task.isCancelled,
                      tab.selectionTranslationOperationID == operationID,
                      tab.url == pageURL else { return }
                SelectionCardController.shared.presentFailure(
                    title: Self.selectionTranslationFailedTitle,
                    message: error.localizedDescription
                )
            }
        }
    }

    private static var selectionTranslationFailedTitle: String {
        NSLocalizedString(
            "translation.selection.failedTitle",
            value: "Selection translation failed",
            comment: "Selection translation - Card title shown when selected text could not be translated"
        )
    }
}
