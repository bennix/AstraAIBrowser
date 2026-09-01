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
                await content.removeImmersiveTranslations(expectedPageURL: pageURL)
                guard tab.url == pageURL else { return }
                tab.immersiveTranslationState = .inactive
            }
            return
        }
        guard tab.immersiveTranslationState != .translating else { return }

        ImmersiveTranslationPreferences.saveLanguage(language)
        ImmersiveTranslationPreferences.saveProvider(provider)
        tab.immersiveTranslationState = .translating

        Task { @MainActor [weak tab] in
            guard let tab else { return }
            do {
                let segments = try await content.immersiveTranslationSegments(
                    expectedPageURL: pageURL
                )
                guard !segments.isEmpty else { throw ImmersiveTranslationError.emptyPage }

                let translations: [ImmersiveTranslationSegment]
                switch provider {
                case .onDevice:
                    guard #available(macOS 26.0, *) else {
                        throw ImmersiveTranslationError.onDeviceUnavailable
                    }
                    translations = try await OnDeviceImmersiveTranslator.translate(
                        segments,
                        to: language
                    )
                case .zenMux:
                    guard let apiKey = try ZenMuxCredentialStore.shared.loadAPIKey(),
                          !apiKey.isEmpty else {
                        throw ImmersiveTranslationError.missingZenMuxCredential
                    }
                    translations = try await APIClient.shared.translateImmersiveSegments(
                        segments,
                        to: language,
                        apiKey: apiKey,
                        model: PhiPreferences.AISettings.loadZenMuxModel()
                    )
                }

                guard tab.url == pageURL else { throw ImmersiveTranslationError.pageChanged }
                let applied = await content.applyImmersiveTranslations(
                    translations,
                    targetLanguage: language.rawValue,
                    expectedPageURL: pageURL
                )
                guard applied else { throw ImmersiveTranslationError.pageChanged }
                tab.immersiveTranslationState = .active(language: language, provider: provider)
            } catch {
                guard tab.url == pageURL else { return }
                tab.immersiveTranslationState = .failed(error.localizedDescription)
            }
        }
    }
}
