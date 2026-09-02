// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Popover card anchored at the pointer inside the browser window. It shows
/// the result of a selection action — a dictionary lookup or a translation —
/// and stays until the user clicks elsewhere or presses Escape.
@MainActor
final class SelectionCardController: NSObject, NSPopoverDelegate {
    static let shared = SelectionCardController()

    enum State: Equatable {
        case lookingUp(word: String)
        case lookup(VocabularyWordLookup, isSaved: Bool)
        case translating(original: String)
        case translation(original: String, translated: String)
        case failed(title: String, message: String)
    }

    final class Model: ObservableObject {
        @Published var state: State = .lookingUp(word: "")
        @Published var languageName = ""
        var onAdd: (() -> Void)?
    }

    private let model = Model()
    private var popover: NSPopover?
    private var hostingController: NSHostingController<SelectionCard>?

    private override init() {
        super.init()
    }

    func presentLookingUp(word: String, language: ImmersiveTranslationLanguage) {
        model.languageName = language.displayName
        model.onAdd = nil
        model.state = .lookingUp(word: word)
        show()
    }

    func presentLookup(
        _ lookup: VocabularyWordLookup,
        language: ImmersiveTranslationLanguage,
        isSaved: Bool,
        onAdd: @escaping () -> Void
    ) {
        model.languageName = language.displayName
        model.onAdd = { [weak self] in
            onAdd()
            self?.model.state = .lookup(lookup, isSaved: true)
        }
        model.state = .lookup(lookup, isSaved: isSaved)
        show()
    }

    func presentTranslating(original: String, language: ImmersiveTranslationLanguage) {
        model.languageName = language.displayName
        model.onAdd = nil
        model.state = .translating(original: original)
        show()
    }

    func presentTranslation(
        original: String,
        translated: String,
        language: ImmersiveTranslationLanguage
    ) {
        model.languageName = language.displayName
        model.onAdd = nil
        model.state = .translation(original: original, translated: translated)
        show()
    }

    func presentFailure(title: String, message: String) {
        model.onAdd = nil
        model.state = .failed(title: title, message: message)
        show()
    }

    func dismiss() {
        popover?.performClose(nil)
    }

    private func show() {
        if let popover, popover.isShown {
            return
        }
        guard let anchor = Self.anchorUnderPointer() else {
            AppLogWarn("[SelectionCard] no visible window under the pointer; card not shown")
            NSSound.beep()
            return
        }
        let controller = hostingController ?? makeHostingController()
        let popover = self.popover ?? makePopover(contentViewController: controller)
        self.hostingController = controller
        self.popover = popover
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minY)
        AppLogInfo(
            "[SelectionCard] shown window=\(anchor.view.window?.windowNumber ?? -1) rect=\(NSStringFromRect(anchor.rect))"
        )
    }

    private func makeHostingController() -> NSHostingController<SelectionCard> {
        let controller = NSHostingController(rootView: SelectionCard(model: model))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func makePopover(contentViewController: NSViewController) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentViewController
        popover.delegate = self
        return popover
    }

    /// The window content view under the pointer and a 1×1 rect at the
    /// pointer in that view's coordinates. Falls back to the key window so a
    /// card triggered from the keyboard still has somewhere to attach.
    private static func anchorUnderPointer() -> (view: NSView, rect: NSRect)? {
        let pointer = NSEvent.mouseLocation
        let candidates = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        let window = candidates.first { $0.frame.contains(pointer) }
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? candidates.first
        guard let window, let view = window.contentView else { return nil }
        var point = window.convertPoint(fromScreen: pointer)
        point = view.convert(point, from: nil)
        let bounds = view.bounds
        let clamped = NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        return (view, NSRect(origin: clamped, size: NSSize(width: 1, height: 1)))
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.onAdd = nil
        }
    }
}

private struct SelectionCard: View {
    @ObservedObject var model: SelectionCardController.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .lookingUp(let word):
                headline(word)
                progressRow(NSLocalizedString(
                    "vocabulary.lookupCard.loading",
                    value: "Looking up…",
                    comment: "Word lookup card - Status shown while the dictionary meaning is being fetched"
                ))
            case .lookup(let lookup, let isSaved):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    headline(lookup.word)
                    if !lookup.partOfSpeech.isEmpty {
                        Text(lookup.partOfSpeech)
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    languageBadge
                }
                Text(lookup.translation)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if isSaved {
                        Label(
                            NSLocalizedString(
                                "vocabulary.lookupCard.savedLabel",
                                value: "In Vocabulary Book",
                                comment: "Word lookup card - Label shown when the word is already saved"
                            ),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.onAdd?()
                        } label: {
                            Label(
                                NSLocalizedString(
                                    "vocabulary.lookupCard.addAction",
                                    value: "Add to Vocabulary Book",
                                    comment: "Word lookup card - Button that saves the looked-up word"
                                ),
                                systemImage: "plus.circle"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            case .translating(let original):
                excerpt(original)
                progressRow(NSLocalizedString(
                    "translation.selection.progressTitle",
                    value: "Translating selection…",
                    comment: "Selection translation - Brief toast shown while selected webpage text is being translated"
                ))
            case .translation(let original, let translated):
                HStack(alignment: .firstTextBaseline) {
                    excerpt(original)
                    Spacer(minLength: 0)
                    languageBadge
                }
                Divider()
                ScrollView {
                    Text(translated)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                HStack {
                    Spacer()
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(translated, forType: .string)
                    } label: {
                        Label(
                            NSLocalizedString(
                                "translation.selection.copyAction",
                                value: "Copy Translation",
                                comment: "Selection translation card - Button that copies the translated text"
                            ),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .controlSize(.small)
                }
            case .failed(let title, let message):
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .textSelection(.enabled)
    }

    private func excerpt(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .truncationMode(.tail)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var languageBadge: some View {
        Text(model.languageName)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
