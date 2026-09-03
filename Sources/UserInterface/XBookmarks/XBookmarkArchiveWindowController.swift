// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class XBookmarkArchiveWindowController: NSWindowController {
    private let store = XBookmarkArchiveDocumentStore()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: XBookmarkArchiveDocumentView(store: store))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ document: XBookmarkMarkdownDocument) {
        store.document = document
        guard let window else { return }
        window.title = document.title
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class XBookmarkArchiveDocumentStore: ObservableObject {
    @Published var document: XBookmarkMarkdownDocument?
}

private struct XBookmarkArchiveDocumentView: View {
    @ObservedObject var store: XBookmarkArchiveDocumentStore
    @State private var showsCopiedFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                Text(store.document?.markdown ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if let document = store.document {
                Text(document.kind == .classified
                     ? NSLocalizedString(
                        "xBookmarks.archive.classifiedBadge",
                        value: "ZenMux classified",
                        comment: "X bookmark archive window - Label identifying an AI-classified Markdown document"
                     )
                     : NSLocalizedString(
                        "xBookmarks.archive.rawBadge",
                        value: "Raw archive",
                        comment: "X bookmark archive window - Label identifying a raw Markdown document"
                     ))
                    .font(.callout.weight(.semibold))
                Text(document.createdAt, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copyMarkdown()
            } label: {
                Label(
                    showsCopiedFeedback
                        ? NSLocalizedString(
                            "xBookmarks.archive.copiedLabel",
                            value: "Copied",
                            comment: "X bookmark archive window - Temporary confirmation after copying Markdown"
                        )
                        : NSLocalizedString(
                            "xBookmarks.archive.copyAction",
                            value: "Copy Markdown",
                            comment: "X bookmark archive window - Button copying the current Markdown document"
                        ),
                    systemImage: showsCopiedFeedback ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(store.document == nil)

            Button {
                saveMarkdown()
            } label: {
                Label(
                    NSLocalizedString(
                        "xBookmarks.archive.saveAction",
                        value: "Save Markdown…",
                        comment: "X bookmark archive window - Button saving the current Markdown document to disk"
                    ),
                    systemImage: "square.and.arrow.down"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.document == nil)
        }
        .padding(12)
    }

    private func copyMarkdown() {
        guard let markdown = store.document?.markdown else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        showsCopiedFeedback = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showsCopiedFeedback = false
        }
    }

    private func saveMarkdown() {
        guard let document = store.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = document.suggestedFilename
        panel.title = NSLocalizedString(
            "xBookmarks.archive.savePanelTitle",
            value: "Save X Bookmark Archive",
            comment: "X bookmark archive window - Save panel title for a Markdown document"
        )
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try document.markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
