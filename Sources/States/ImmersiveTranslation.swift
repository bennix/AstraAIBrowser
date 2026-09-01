// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import NaturalLanguage
import Translation

struct ImmersiveTranslationSegment: Codable, Equatable, Sendable {
    let id: String
    let text: String
}

struct ImmersiveTranslationPageSnapshot: Equatable, Sendable {
    let sessionID: String
    let segments: [ImmersiveTranslationSegment]
}

enum ImmersiveTranslationBatchPlanner {
    static let maximumSegmentCount = 8
    static let maximumCharacterCount = 4_000

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

enum SelectionTranslationPolicy {
    static let maximumCharacterCount = 6_000

    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ImmersiveTranslationLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
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
    case onDevice = "on_device"
    case zenMux = "zenmux"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice:
            return NSLocalizedString(
                "translation.provider.onDevice",
                value: "On-device",
                comment: "Immersive translation - On-device provider name"
            )
        case .zenMux:
            return NSLocalizedString(
                "translation.provider.zenMux",
                value: "ZenMux enhanced",
                comment: "Immersive translation - ZenMux provider name"
            )
        }
    }
}

enum ImmersiveTranslationState: Equatable {
    case inactive
    case translating
    case active(language: ImmersiveTranslationLanguage, provider: ImmersiveTranslationProvider)
    case failed(String)
}

enum ImmersiveTranslationPreferences {
    private static let languageKey = "immersiveTranslation.targetLanguage"
    private static let providerKey = "immersiveTranslation.provider"

    static func loadLanguage(from defaults: UserDefaults = .standard) -> ImmersiveTranslationLanguage {
        defaults.string(forKey: languageKey)
            .flatMap(ImmersiveTranslationLanguage.init(rawValue:))
            ?? .simplifiedChinese
    }

    static func saveLanguage(
        _ language: ImmersiveTranslationLanguage,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: languageKey)
    }

    static func loadProvider(from defaults: UserDefaults = .standard) -> ImmersiveTranslationProvider {
        defaults.string(forKey: providerKey)
            .flatMap(ImmersiveTranslationProvider.init(rawValue:))
            ?? .onDevice
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
    case onDeviceUnavailable
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
        case .onDeviceUnavailable:
            return NSLocalizedString(
                "translation.error.onDeviceUnavailable",
                value: "On-device translation is unavailable for this language pair. Choose ZenMux enhanced translation instead.",
                comment: "Immersive translation - On-device language pair unavailable error"
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

@available(macOS 26.0, *)
private enum OnDeviceImmersiveTranslator {
    static func translate(
        _ segments: [ImmersiveTranslationSegment],
        to targetLanguage: ImmersiveTranslationLanguage
    ) async throws -> [ImmersiveTranslationSegment] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(segments.prefix(20).map(\.text).joined(separator: "\n"))
        guard let source = recognizer.dominantLanguage,
              source != .undetermined else {
            throw ImmersiveTranslationError.onDeviceUnavailable
        }
        if source.rawValue == targetLanguage.rawValue {
            return segments
        }

        let session = TranslationSession(
            installedSource: Locale.Language(identifier: source.rawValue),
            target: Locale.Language(identifier: targetLanguage.rawValue)
        )
        let requests = segments.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch {
            throw ImmersiveTranslationError.onDeviceUnavailable
        }
        let translatedByID = Dictionary(uniqueKeysWithValues: responses.compactMap { response in
            response.clientIdentifier.map { ($0, response.targetText) }
        })
        return segments.compactMap { segment in
            translatedByID[segment.id].map {
                ImmersiveTranslationSegment(id: segment.id, text: $0)
            }
        }
    }
}

extension BrowserState {
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
        case .onDevice:
            guard #available(macOS 26.0, *) else {
                throw ImmersiveTranslationError.onDeviceUnavailable
            }
            return try await OnDeviceImmersiveTranslator.translate(
                segments,
                to: language
            )
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
        provider: ImmersiveTranslationProvider
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
                let snapshot = try await content.immersiveTranslationSnapshot()
                try Task.checkCancellation()
                let segments = snapshot.segments
                guard !segments.isEmpty else { throw ImmersiveTranslationError.emptyPage }
                let batches = ImmersiveTranslationBatchPlanner.batches(for: segments)
                var completedTranslations: [ImmersiveTranslationSegment] = []
                completedTranslations.reserveCapacity(segments.count)

                for batch in batches {
                    try Task.checkCancellation()
                    let translations = try await self.translateImmersiveBatch(
                        batch,
                        language: language,
                        provider: provider
                    )
                    guard translations.map(\.id) == batch.map(\.id) else {
                        throw ImmersiveTranslationError.pageChanged
                    }
                    completedTranslations.append(contentsOf: translations)

                    try Task.checkCancellation()
                    guard tab.immersiveTranslationOperationID == operationID,
                          tab.webContentWrapper === content,
                          tab.immersiveTranslationState == .translating else { return }
                    let applied = await content.applyImmersiveTranslations(
                        completedTranslations,
                        targetLanguage: language.rawValue,
                        sessionID: snapshot.sessionID
                    )
                    try Task.checkCancellation()
                    guard tab.immersiveTranslationOperationID == operationID else { return }
                    guard applied else { throw ImmersiveTranslationError.pageChanged }
                }

                tab.immersiveTranslationState = .active(language: language, provider: provider)
            } catch {
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
            OverlayToastCenter.shared.show(
                title: NSLocalizedString(
                    "translation.selection.failedTitle",
                    value: "Selection translation failed",
                    comment: "Selection translation - Toast title shown when selected text could not be translated"
                ),
                message: ImmersiveTranslationError.selectionTooLong.localizedDescription,
                duration: 6,
                in: self
            )
            return
        }

        tab.selectionTranslationTask?.cancel()
        let operationID = UUID()
        let pageURL = tab.url
        tab.selectionTranslationOperationID = operationID
        OverlayToastCenter.shared.show(
            title: NSLocalizedString(
                "translation.selection.progressTitle",
                value: "Translating selection…",
                comment: "Selection translation - Brief toast shown while selected webpage text is being translated"
            ),
            duration: 1.2,
            in: self
        )

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
                guard tab.selectionTranslationOperationID == operationID,
                      tab.url == pageURL,
                      self.tabs.contains(where: { $0 === tab }),
                      let translation = translations.first,
                      translation.id == segment.id else { return }
                let title = String(
                    format: NSLocalizedString(
                        "translation.selection.resultTitle",
                        value: "Translated to %@",
                        comment: "Selection translation - Result toast title; placeholder is the target language name"
                    ),
                    language.displayName
                )
                OverlayToastCenter.shared.show(
                    title: title,
                    message: translation.text,
                    duration: 8,
                    in: self
                )
            } catch {
                guard !Task.isCancelled,
                      tab.selectionTranslationOperationID == operationID,
                      tab.url == pageURL else { return }
                OverlayToastCenter.shared.show(
                    title: NSLocalizedString(
                        "translation.selection.failedTitle",
                        value: "Selection translation failed",
                        comment: "Selection translation - Toast title shown when selected text could not be translated"
                    ),
                    message: error.localizedDescription,
                    duration: 6,
                    in: self
                )
            }
        }
    }
}
