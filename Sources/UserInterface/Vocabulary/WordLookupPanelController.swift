// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Floating card shown next to the pointer after "Look Up Word" is chosen.
/// It stays until the user clicks elsewhere or presses Escape.
@MainActor
final class WordLookupPanelController {
    static let shared = WordLookupPanelController()

    enum State: Equatable {
        case loading(word: String)
        case result(VocabularyWordLookup, isSaved: Bool)
        case failed(String)
    }

    final class Model: ObservableObject {
        @Published var state: State = .loading(word: "")
        @Published var languageName = ""
        var onAdd: (() -> Void)?
        var onClose: (() -> Void)?
    }

    private let model = Model()
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?

    private init() {}

    func presentLoading(word: String, language: ImmersiveTranslationLanguage) {
        model.languageName = language.displayName
        model.state = .loading(word: word)
        model.onAdd = nil
        show()
    }

    func presentResult(
        _ lookup: VocabularyWordLookup,
        language: ImmersiveTranslationLanguage,
        isSaved: Bool,
        onAdd: @escaping () -> Void
    ) {
        model.languageName = language.displayName
        model.onAdd = { [weak self] in
            onAdd()
            self?.model.state = .result(lookup, isSaved: true)
        }
        model.state = .result(lookup, isSaved: isSaved)
        show()
    }

    func presentFailure(_ message: String) {
        model.onAdd = nil
        model.state = .failed(message)
        show()
    }

    func dismiss() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionNearPointer(panel)
        panel.orderFrontRegardless()
        installMonitors()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        model.onClose = { [weak self] in self?.dismiss() }
        let hosting = NSHostingView(rootView: WordLookupCard(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        return panel
    }

    private func positionNearPointer(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let pointer = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens
            .first { $0.frame.contains(pointer) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        var origin = NSPoint(x: pointer.x + 12, y: pointer.y - size.height - 12)
        if origin.x + size.width > screenFrame.maxX {
            origin.x = max(screenFrame.minX, pointer.x - size.width - 12)
        }
        if origin.y < screenFrame.minY {
            origin.y = min(screenFrame.maxY - size.height, pointer.y + 12)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            let isKeyDown = event.type == .keyDown
            let isEscape = isKeyDown && event.keyCode == 53
            let eventWindow = event.window
            let swallowsEvent: Bool = MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return false }
                if isKeyDown {
                    guard isEscape else { return false }
                    self.dismiss()
                    return true
                }
                if eventWindow !== panel {
                    self.dismiss()
                }
                return false
            }
            return swallowsEvent ? nil : event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

private struct WordLookupCard: View {
    @ObservedObject var model: WordLookupPanelController.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .loading(let word):
                Text(word)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString(
                        "vocabulary.lookupCard.loading",
                        value: "Looking up…",
                        comment: "Word lookup card - Status shown while the dictionary meaning is being fetched"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            case .result(let lookup, let isSaved):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lookup.word)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    if !lookup.partOfSpeech.isEmpty {
                        Text(lookup.partOfSpeech)
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(model.languageName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            case .failed(let message):
                Text(NSLocalizedString(
                    "vocabulary.selection.lookUpFailedTitle",
                    value: "Word lookup failed",
                    comment: "Word lookup - Toast title shown when the selected word could not be looked up"
                ))
                .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}
