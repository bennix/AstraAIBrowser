// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standalone window listing every saved word with Markdown export.
@MainActor
final class VocabularyBookWindowController: NSWindowController {
    static let shared = VocabularyBookWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VocabularyBookWindow")
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: VocabularyBookView(store: VocabularyBookStore.shared)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static var windowTitle: String {
        NSLocalizedString(
            "vocabulary.window.title",
            value: "Vocabulary Book",
            comment: "Vocabulary book - Window title of the saved words list"
        )
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct VocabularyBookView: View {
    @ObservedObject var store: VocabularyBookStore
    @State private var searchText = ""
    @State private var selection: Set<UUID> = []
    @State private var showsClearConfirmation = false
    @State private var showsCopiedFeedback = false

    private var filteredEntries: [VocabularyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.word.localizedCaseInsensitiveContains(query)
                || $0.translation.localizedCaseInsensitiveContains(query)
                || $0.partOfSpeech.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.entries.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .confirmationDialog(
            NSLocalizedString(
                "vocabulary.window.clearConfirmation.title",
                value: "Remove all saved words?",
                comment: "Vocabulary book - Confirmation title before deleting every saved word"
            ),
            isPresented: $showsClearConfirmation
        ) {
            Button(role: .destructive) {
                store.removeAll()
                selection.removeAll()
            } label: {
                Text(NSLocalizedString(
                    "vocabulary.window.clearConfirmation.confirmAction",
                    value: "Remove All",
                    comment: "Vocabulary book - Destructive button that deletes every saved word"
                ))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField(
                NSLocalizedString(
                    "vocabulary.window.searchPlaceholder",
                    value: "Search words",
                    comment: "Vocabulary book - Placeholder of the search field filtering saved words"
                ),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)

            Text(String(
                format: NSLocalizedString(
                    "vocabulary.window.countLabel",
                    value: "%d words",
                    comment: "Vocabulary book - Count of saved words; placeholder is the number"
                ),
                store.entries.count
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                deleteSelection()
            } label: {
                Label(
                    NSLocalizedString(
                        "vocabulary.window.deleteSelectedAction",
                        value: "Delete",
                        comment: "Vocabulary book - Button that removes the selected words"
                    ),
                    systemImage: "trash"
                )
            }
            .disabled(selection.isEmpty)

            Button {
                showsClearConfirmation = true
            } label: {
                Text(NSLocalizedString(
                    "vocabulary.window.clearAllAction",
                    value: "Clear All",
                    comment: "Vocabulary book - Button that removes every saved word after confirmation"
                ))
            }
            .disabled(store.entries.isEmpty)

            Button {
                copyMarkdown()
            } label: {
                Label(
                    showsCopiedFeedback
                        ? NSLocalizedString(
                            "vocabulary.window.copiedLabel",
                            value: "Copied",
                            comment: "Vocabulary book - Short confirmation replacing the copy button title right after the list was copied"
                        )
                        : NSLocalizedString(
                            "vocabulary.window.copyMarkdownAction",
                            value: "Copy Markdown",
                            comment: "Vocabulary book - Button that copies the whole list as a Markdown table"
                        ),
                    systemImage: showsCopiedFeedback ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(store.entries.isEmpty)

            Button {
                exportMarkdown()
            } label: {
                Label(
                    NSLocalizedString(
                        "vocabulary.window.exportMarkdownAction",
                        value: "Export Markdown…",
                        comment: "Vocabulary book - Button that saves the list as a Markdown file"
                    ),
                    systemImage: "square.and.arrow.up"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.entries.isEmpty)
        }
        .padding(12)
    }

    private var table: some View {
        Table(filteredEntries, selection: $selection) {
            TableColumn(NSLocalizedString(
                "vocabulary.window.column.word",
                value: "Word",
                comment: "Vocabulary book - Table column header for the saved word"
            )) { entry in
                Text(entry.word).fontWeight(.semibold)
            }
            .width(min: 120, ideal: 180)

            TableColumn(NSLocalizedString(
                "vocabulary.window.column.partOfSpeech",
                value: "Part of Speech",
                comment: "Vocabulary book - Table column header for the word class such as noun or verb"
            )) { entry in
                Text(entry.partOfSpeech).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn(NSLocalizedString(
                "vocabulary.window.column.translation",
                value: "Translation",
                comment: "Vocabulary book - Table column header for the translated meaning"
            )) { entry in
                Text(entry.translation)
            }

            TableColumn(NSLocalizedString(
                "vocabulary.window.column.added",
                value: "Added",
                comment: "Vocabulary book - Table column header for the date the word was saved"
            )) { entry in
                Text(entry.createdAt, format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button(role: .destructive) {
                store.remove(ids: ids)
                selection.subtract(ids)
            } label: {
                Text(NSLocalizedString(
                    "vocabulary.window.deleteContextAction",
                    value: "Delete",
                    comment: "Vocabulary book - Context menu action removing the right-clicked words"
                ))
            }
        }
        .onDeleteCommand(perform: deleteSelection)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString(
                "vocabulary.window.emptyTitle",
                value: "No saved words yet",
                comment: "Vocabulary book - Title shown when the list is empty"
            ))
            .font(.headline)
            Text(NSLocalizedString(
                "vocabulary.window.emptyMessage",
                value: "Select a word on any page, right-click, and choose “Add to Vocabulary Book”.",
                comment: "Vocabulary book - Hint shown when the list is empty explaining how to add words"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        store.remove(ids: selection)
        selection.removeAll()
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.markdown(), forType: .string)
        showsCopiedFeedback = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showsCopiedFeedback = false
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Vocabulary Book.md"
        panel.title = NSLocalizedString(
            "vocabulary.window.exportPanel.title",
            value: "Export Vocabulary Book",
            comment: "Vocabulary book - Save panel title when exporting the list as Markdown"
        )
        panel.canCreateDirectories = true
        let markdown = store.markdown()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
