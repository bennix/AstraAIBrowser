// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

enum XBookmarkDigestState: Equatable {
    case inactive
    case collecting(count: Int)
    case paused(count: Int)
    case ready(count: Int)
    case summarizing(count: Int)
    case completed(count: Int)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .collecting, .summarizing:
            return true
        case .inactive, .paused, .ready, .completed, .failed:
            return false
        }
    }

    var collectedCount: Int {
        switch self {
        case .collecting(let count), .paused(let count), .ready(let count),
             .summarizing(let count), .completed(let count):
            return count
        case .inactive, .failed:
            return 0
        }
    }
}

enum XBookmarkDigestError: LocalizedError {
    case unavailablePage
    case noBookmarks
    case timelineFailed
    case collectionLimitReached
    case conversationBusy

    var errorDescription: String? {
        switch self {
        case .unavailablePage:
            return NSLocalizedString(
                "xBookmarks.error.unavailablePage",
                value: "Open the signed-in X bookmarks page before starting.",
                comment: "X bookmark digest - Error shown when collection is started outside the supported bookmarks page"
            )
        case .noBookmarks:
            return NSLocalizedString(
                "xBookmarks.error.noBookmarks",
                value: "No bookmark posts were found. Check that X is signed in and the bookmarks timeline is visible.",
                comment: "X bookmark digest - Error shown when the automatic collector cannot find any bookmark posts"
            )
        case .timelineFailed:
            return NSLocalizedString(
                "xBookmarks.error.timelineFailed",
                value: "X stopped loading the bookmarks timeline. Retry after the page recovers.",
                comment: "X bookmark digest - Error shown when X displays a timeline loading failure during collection"
            )
        case .collectionLimitReached:
            return NSLocalizedString(
                "xBookmarks.error.collectionLimitReached",
                value: "Collection stopped before the end of the bookmarks timeline could be verified.",
                comment: "X bookmark digest - Error shown when the collector safety limit is reached before timeline completion"
            )
        case .conversationBusy:
            return NSLocalizedString(
                "xBookmarks.error.conversationBusy",
                value: "Wait for the current ZenMux response to finish, then try again.",
                comment: "X bookmark digest - Error shown when the tab AI conversation is already generating a response"
            )
        }
    }
}

enum XBookmarkDigestPolicy {
    static let maximumCollectionPasses = 10_000
    static let requiredStableBottomPasses = 8
    static let maximumReadinessPasses = 60
    static let readinessPollMilliseconds = 500
    static let bookmarkRoutePaths = ["/i/history", "/i/bookmarks", "/bookmarks"]

    static func isXURL(_ rawValue: String?) -> Bool {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "x.com"
            || host.hasSuffix(".x.com")
            || host == "twitter.com"
            || host.hasSuffix(".twitter.com")
    }

    static func isBookmarksURL(_ rawValue: String?) -> Bool {
        guard isXURL(rawValue),
              let rawValue,
              let url = URL(string: rawValue) else { return false }
        let path = "/" + url.path.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return bookmarkRoutePaths.contains(path)
    }
}

struct XBookmarkDigestAccumulator {
    struct Update: Equatable {
        let newItemCount: Int
        let totalCount: Int
        let reachedEnd: Bool
    }

    private var valuesByID: [String: XBookmarkContent] = [:]
    private var orderedIDs: [String] = []
    private var lastScrollHeight: Double?
    private var stableBottomPasses = 0
    private let requiredStableBottomPasses: Int

    init(requiredStableBottomPasses: Int = XBookmarkDigestPolicy.requiredStableBottomPasses) {
        self.requiredStableBottomPasses = max(1, requiredStableBottomPasses)
    }

    var items: [XBookmarkContent] {
        orderedIDs.compactMap { valuesByID[$0] }
    }

    mutating func ingest(_ snapshot: XBookmarkPageSnapshot) -> Update {
        var newItemCount = 0
        for item in snapshot.items {
            if let existing = valuesByID[item.id] {
                if item.contentWeight > existing.contentWeight {
                    valuesByID[item.id] = item
                }
            } else {
                valuesByID[item.id] = item
                orderedIDs.append(item.id)
                newItemCount += 1
            }
        }

        let heightIsStable = lastScrollHeight.map {
            abs($0 - snapshot.scrollHeight) <= 4
        } ?? false
        if snapshot.isAtBottom,
           !snapshot.isLoading,
           snapshot.isTimelineReady,
           (!valuesByID.isEmpty || snapshot.isExplicitlyEmpty),
           !snapshot.hasTimelineError,
           newItemCount == 0,
           heightIsStable {
            stableBottomPasses += 1
        } else {
            stableBottomPasses = 0
        }
        lastScrollHeight = snapshot.scrollHeight

        return Update(
            newItemCount: newItemCount,
            totalCount: valuesByID.count,
            reachedEnd: stableBottomPasses >= requiredStableBottomPasses
        )
    }
}

enum XBookmarkDigestBatchPlanner {
    static func batches(
        for items: [XBookmarkContent],
        maximumItemCount: Int = 60,
        maximumCharacterCount: Int = 45_000
    ) -> [[XBookmarkContent]] {
        let itemLimit = max(1, maximumItemCount)
        let characterLimit = max(1, maximumCharacterCount)
        var result: [[XBookmarkContent]] = []
        var batch: [XBookmarkContent] = []
        var characterCount = 0

        for item in items {
            let itemCharacters = max(1, item.estimatedCharacterCount)
            if !batch.isEmpty,
               (batch.count >= itemLimit || characterCount + itemCharacters > characterLimit) {
                result.append(batch)
                batch = []
                characterCount = 0
            }
            batch.append(item)
            characterCount += itemCharacters
        }
        if !batch.isEmpty {
            result.append(batch)
        }
        return result
    }
}

struct XBookmarkMarkdownDocument: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case raw
        case classified
    }

    let title: String
    let suggestedFilename: String
    let markdown: String
    let kind: Kind
    let createdAt: Date
}

final class XBookmarkCollectionSession {
    var accumulator = XBookmarkDigestAccumulator()
    var hasPreparedTimeline = false
    var reachedEnd = false
    var document: XBookmarkMarkdownDocument?
    let startedAt = Date()

    var items: [XBookmarkContent] {
        accumulator.items
    }
}

enum XBookmarkMarkdownExporter {
    static func rawDocument(
        for items: [XBookmarkContent],
        collectedAt: Date = Date()
    ) -> XBookmarkMarkdownDocument {
        let day = filenameDateFormatter.string(from: collectedAt)
        let title = NSLocalizedString(
            "xBookmarks.archive.rawTitle",
            value: "X Bookmark Archive",
            comment: "X bookmark archive - Title of a raw Markdown archive"
        )
        return XBookmarkMarkdownDocument(
            title: title,
            suggestedFilename: String(
                format: NSLocalizedString(
                    "xBookmarks.archive.rawFilenameFormat",
                    value: "X Bookmarks %@.md",
                    comment: "X bookmark archive - Suggested raw Markdown filename; placeholder is the export date"
                ),
                day
            ),
            markdown: rawMarkdown(for: items, collectedAt: collectedAt),
            kind: .raw,
            createdAt: collectedAt
        )
    }

    static func classifiedDocument(
        report: String,
        itemCount: Int,
        collectedAt: Date = Date()
    ) -> XBookmarkMarkdownDocument {
        let day = filenameDateFormatter.string(from: collectedAt)
        let heading = NSLocalizedString(
            "xBookmarks.archive.classifiedTitle",
            value: "X Bookmark Archive — AI Classification",
            comment: "X bookmark archive - Title of a ZenMux-classified Markdown archive"
        )
        let metadata = String(
            format: NSLocalizedString(
                "xBookmarks.archive.classifiedMetadataFormat",
                value: "Collected %1$ld posts · Generated %2$@",
                comment: "X bookmark archive - AI report metadata; first placeholder is the post count and second is the generation date"
            ),
            itemCount,
            displayDateFormatter.string(from: collectedAt)
        )
        return XBookmarkMarkdownDocument(
            title: heading,
            suggestedFilename: String(
                format: NSLocalizedString(
                    "xBookmarks.archive.classifiedFilenameFormat",
                    value: "X Bookmarks AI %@.md",
                    comment: "X bookmark archive - Suggested classified Markdown filename; placeholder is the export date"
                ),
                day
            ),
            markdown: "# \(heading)\n\n\(metadata)\n\n\(report.trimmingCharacters(in: .whitespacesAndNewlines))\n",
            kind: .classified,
            createdAt: collectedAt
        )
    }

    static func rawMarkdown(
        for items: [XBookmarkContent],
        collectedAt: Date = Date()
    ) -> String {
        let title = NSLocalizedString(
            "xBookmarks.archive.rawTitle",
            value: "X Bookmark Archive",
            comment: "X bookmark archive - Title of a raw Markdown archive"
        )
        var lines = [
            "# \(title)",
            "",
            String(
                format: NSLocalizedString(
                    "xBookmarks.archive.rawMetadataFormat",
                    value: "Collected %1$ld posts · Exported %2$@",
                    comment: "X bookmark archive - Raw archive metadata; first placeholder is the post count and second is the export date"
                ),
                items.count,
                displayDateFormatter.string(from: collectedAt)
            ),
            "",
        ]
        for (index, item) in items.enumerated() {
            let author = [item.authorName, item.authorHandle]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let fallbackTitle = NSLocalizedString(
                "xBookmarks.archive.savedPostTitle",
                value: "Saved post",
                comment: "X bookmark archive - Fallback heading when a saved post has no author"
            )
            lines.append("## \(index + 1). \(author.isEmpty ? fallbackTitle : author)")
            lines.append("")
            appendMetadata(label: dateLabel, value: item.postedAt, to: &lines)
            appendMetadata(label: sourceLabel, value: item.url, to: &lines)
            appendMetadata(label: languageLabel, value: item.language, to: &lines)
            appendSection(title: postSection, value: item.text, to: &lines)
            appendSection(title: quotedPostSection, value: item.quotedText, to: &lines)
            if !item.visibleContent.isEmpty,
               item.visibleContent != item.text,
               item.visibleContent != item.quotedText {
                appendSection(
                    title: visibleDetailsSection,
                    value: item.visibleContent,
                    to: &lines
                )
            }
            appendList(title: linksSection, values: item.links, to: &lines)
            appendList(title: imagesSection, values: item.imageURLs, to: &lines)
            appendList(
                title: videosSection,
                values: item.videoURLs,
                to: &lines
            )
            appendList(
                title: mediaDescriptionsSection,
                values: item.mediaDescriptions,
                to: &lines
            )
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateLabel = NSLocalizedString(
        "xBookmarks.archive.dateLabel",
        value: "Date",
        comment: "X bookmark archive - Markdown metadata label for the post date"
    )
    private static let sourceLabel = NSLocalizedString(
        "xBookmarks.archive.sourceLabel",
        value: "Source",
        comment: "X bookmark archive - Markdown metadata label for the original post URL"
    )
    private static let languageLabel = NSLocalizedString(
        "xBookmarks.archive.languageLabel",
        value: "Language",
        comment: "X bookmark archive - Markdown metadata label for the detected post language"
    )
    private static let postSection = NSLocalizedString(
        "xBookmarks.archive.postSection",
        value: "Post",
        comment: "X bookmark archive - Markdown section heading for the complete post text"
    )
    private static let quotedPostSection = NSLocalizedString(
        "xBookmarks.archive.quotedPostSection",
        value: "Quoted post",
        comment: "X bookmark archive - Markdown section heading for quoted post text"
    )
    private static let visibleDetailsSection = NSLocalizedString(
        "xBookmarks.archive.visibleDetailsSection",
        value: "Visible details",
        comment: "X bookmark archive - Markdown section heading for extra visible post details"
    )
    private static let linksSection = NSLocalizedString(
        "xBookmarks.archive.linksSection",
        value: "Links",
        comment: "X bookmark archive - Markdown section heading for links found in a post"
    )
    private static let imagesSection = NSLocalizedString(
        "xBookmarks.archive.imagesSection",
        value: "Images",
        comment: "X bookmark archive - Markdown section heading for collected image links"
    )
    private static let videosSection = NSLocalizedString(
        "xBookmarks.archive.videosSection",
        value: "Videos (links only)",
        comment: "X bookmark archive - Markdown section heading for video post links that were not downloaded"
    )
    private static let mediaDescriptionsSection = NSLocalizedString(
        "xBookmarks.archive.mediaDescriptionsSection",
        value: "Media descriptions",
        comment: "X bookmark archive - Markdown section heading for accessible media descriptions"
    )

    private static func appendMetadata(label: String, value: String, to lines: inout [String]) {
        guard !value.isEmpty else { return }
        lines.append("- **\(label):** \(value)")
    }

    private static func appendSection(title: String, value: String, to lines: inout [String]) {
        guard !value.isEmpty else { return }
        lines.append("")
        lines.append("### \(title)")
        lines.append("")
        lines.append(value)
    }

    private static func appendList(title: String, values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("")
        lines.append("### \(title)")
        lines.append("")
        lines.append(contentsOf: values.map { "- \($0)" })
    }
}

extension BrowserState {
    static func shouldOfferYouTubeDigest(
        pageURL: String?,
        isAIEnabled: Bool,
        isIncognito: Bool,
        isOverviewActive: Bool,
        isChatAvailable: Bool
    ) -> Bool {
        isAIEnabled
            && !isIncognito
            && !isOverviewActive
            && isChatAvailable
            && APIClient.isYouTubeVideoURL(pageURL)
    }

    static func shouldOfferXBookmarkDigest(
        pageURL: String?,
        isAIEnabled: Bool,
        isIncognito: Bool,
        isOverviewActive: Bool,
        isChatAvailable: Bool
    ) -> Bool {
        isAIEnabled
            && !isIncognito
            && !isOverviewActive
            && isChatAvailable
            && XBookmarkDigestPolicy.isXURL(pageURL)
    }

    /// Starts, pauses, resumes, or opens the result of the focused tab's
    /// resumable X bookmark collection session.
    @MainActor
    func toggleXBookmarkDigest() {
        let aiEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
        guard let tab = focusingTab,
              Self.shouldOfferXBookmarkDigest(
                pageURL: tab.url,
                isAIEnabled: aiEnabled,
                isIncognito: isIncognito,
                isOverviewActive: groupOverviewState != nil,
                isChatAvailable: tab.aiChatEnabled
              ) else {
            NSSound.beep()
            return
        }

        switch tab.xBookmarkDigestState {
        case .collecting:
            pauseXBookmarkDigest(for: tab)
            return
        case .paused:
            startXBookmarkCollection(for: tab)
            return
        case .ready:
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab else { return }
                await self.presentXBookmarkArchiveChoice(for: tab, canResume: false)
            }
            return
        case .completed:
            if let document = tab.xBookmarkCollectionSession?.document {
                showXBookmarkDocument(document, for: tab)
            }
            return
        case .summarizing:
            return
        case .failed:
            if let session = tab.xBookmarkCollectionSession,
               !session.items.isEmpty {
                tab.xBookmarkDigestState = session.reachedEnd
                    ? .ready(count: session.items.count)
                    : .paused(count: session.items.count)
                Task { @MainActor [weak self, weak tab] in
                    guard let self, let tab else { return }
                    await self.presentXBookmarkArchiveChoice(
                        for: tab,
                        canResume: !session.reachedEnd
                    )
                }
                return
            }
            tab.xBookmarkCollectionSession = XBookmarkCollectionSession()
            startXBookmarkCollection(for: tab)
        case .inactive:
            tab.xBookmarkCollectionSession = XBookmarkCollectionSession()
            startXBookmarkCollection(for: tab)
        }
    }

    @MainActor
    func stopXBookmarkDigest() {
        guard let tab = focusingTab,
              tab.xBookmarkCollectionSession != nil else { return }
        pauseXBookmarkDigest(for: tab)
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            await self.presentXBookmarkArchiveChoice(for: tab, canResume: true)
        }
    }

    @MainActor
    private func pauseXBookmarkDigest(for tab: Tab) {
        let count = tab.xBookmarkCollectionSession?.items.count
            ?? tab.xBookmarkDigestState.collectedCount
        tab.xBookmarkDigestTask?.cancel()
        tab.xBookmarkDigestTask = nil
        tab.xBookmarkDigestOperationID = nil
        tab.xBookmarkDigestState = .paused(count: count)
    }

    @MainActor
    private func startXBookmarkCollection(for tab: Tab) {
        guard let provider = tab.webContentWrapper as? XBookmarkCollectionProviding else {
            tab.xBookmarkDigestState = .failed(XBookmarkDigestError.unavailablePage.localizedDescription)
            return
        }
        let collectionSession = tab.xBookmarkCollectionSession ?? XBookmarkCollectionSession()
        tab.xBookmarkCollectionSession = collectionSession
        let operationID = UUID()
        tab.xBookmarkDigestOperationID = operationID
        tab.xBookmarkDigestState = .collecting(count: collectionSession.items.count)
        tab.xBookmarkDigestTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.xBookmarkDigestOperationID == operationID {
                    tab.xBookmarkDigestTask = nil
                    tab.xBookmarkDigestOperationID = nil
                }
            }

            do {
                if !XBookmarkDigestPolicy.isBookmarksURL(tab.url) {
                    try await provider.openXBookmarkTimeline()
                }
                if !collectionSession.hasPreparedTimeline {
                    try await provider.prepareXBookmarkCollection()
                    collectionSession.hasPreparedTimeline = true
                    try await Task.sleep(for: .milliseconds(1_000))
                }
                var reachedEnd = false

                for _ in 0..<XBookmarkDigestPolicy.maximumCollectionPasses {
                    try Task.checkCancellation()
                    guard tab.xBookmarkDigestOperationID == operationID else {
                        throw CancellationError()
                    }
                    let snapshot = try await provider.collectXBookmarkPageSnapshot()
                    try Task.checkCancellation()
                    guard tab.xBookmarkDigestOperationID == operationID else {
                        throw CancellationError()
                    }
                    if snapshot.hasTimelineError {
                        throw XBookmarkDigestError.timelineFailed
                    }
                    let update = collectionSession.accumulator.ingest(snapshot)
                    tab.xBookmarkDigestState = .collecting(count: update.totalCount)
                    if update.reachedEnd {
                        reachedEnd = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(750))
                }

                guard reachedEnd else { throw XBookmarkDigestError.collectionLimitReached }
                let count = collectionSession.items.count
                guard count > 0 else { throw XBookmarkDigestError.noBookmarks }
                collectionSession.reachedEnd = true
                tab.xBookmarkDigestState = .ready(count: count)
                await presentXBookmarkArchiveChoice(for: tab, canResume: false)
            } catch is CancellationError {
                if tab.xBookmarkDigestOperationID == operationID {
                    tab.xBookmarkDigestState = .paused(count: collectionSession.items.count)
                }
            } catch {
                if tab.xBookmarkDigestOperationID == operationID {
                    tab.xBookmarkDigestState = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func presentXBookmarkArchiveChoice(for tab: Tab, canResume: Bool) async {
        guard let collectionSession = tab.xBookmarkCollectionSession,
              !collectionSession.items.isEmpty else {
            tab.xBookmarkDigestState = .failed(XBookmarkDigestError.noBookmarks.localizedDescription)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString(
            "xBookmarks.finish.title",
            value: "Create a Markdown archive?",
            comment: "X bookmark archive - Title asking how collected posts should be turned into Markdown"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "xBookmarks.finish.message",
                value: "%ld posts are collected. ZenMux can classify and organize them, or you can keep the complete raw archive without AI.",
                comment: "X bookmark archive - Choice description after collection stops; placeholder is the collected post count"
            ),
            collectionSession.items.count
        )
        alert.addButton(withTitle: NSLocalizedString(
            "xBookmarks.finish.classifyAction",
            value: "Classify with ZenMux",
            comment: "X bookmark archive - Button sending collected posts to ZenMux for a classified Markdown report"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "xBookmarks.finish.rawAction",
            value: "Keep Raw Markdown",
            comment: "X bookmark archive - Button creating a complete raw Markdown archive without AI"
        ))
        alert.addButton(withTitle: canResume
            ? NSLocalizedString(
                "xBookmarks.finish.continueAction",
                value: "Continue Collection",
                comment: "X bookmark archive - Button dismissing the stop choice and resuming collection"
            )
            : NSLocalizedString(
                "xBookmarks.finish.laterAction",
                value: "Not Now",
                comment: "X bookmark archive - Button postponing Markdown creation after collection completes"
            ))

        let response: NSApplication.ModalResponse
        if let window = windowController?.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn:
            await createClassifiedXBookmarkDocument(for: tab, session: collectionSession)
        case .alertSecondButtonReturn:
            let document = XBookmarkMarkdownExporter.rawDocument(for: collectionSession.items)
            collectionSession.document = document
            tab.xBookmarkDigestState = .completed(count: collectionSession.items.count)
            showXBookmarkDocument(document, for: tab)
        case .alertThirdButtonReturn where canResume:
            startXBookmarkCollection(for: tab)
        default:
            tab.xBookmarkDigestState = canResume
                ? .paused(count: collectionSession.items.count)
                : .ready(count: collectionSession.items.count)
        }
    }

    @MainActor
    private func createClassifiedXBookmarkDocument(
        for tab: Tab,
        session collectionSession: XBookmarkCollectionSession
    ) async {
        let chatSession = zenMuxChatSession(for: tab)
        guard !chatSession.isSending else {
            tab.xBookmarkDigestState = .failed(XBookmarkDigestError.conversationBusy.localizedDescription)
            return
        }
        guard ((try? ZenMuxCredentialStore.shared.loadAPIKey()) ?? nil) != nil else {
            tab.xBookmarkDigestState = .failed(ZenMuxAPIError.invalidCredential.localizedDescription)
            return
        }
        let items = collectionSession.items
        tab.xBookmarkDigestState = .summarizing(count: items.count)
        tab.updateFocusTarget(.aiChat)
        prepareAIChatSidebarOpen(trigger: .button)
        setAIChatCollapsed(for: tab, collapsed: false)
        chatSession.requestFocus()
        guard let report = await chatSession.summarizeXBookmarks(items) else {
            tab.xBookmarkDigestState = .failed(
                chatSession.errorMessage ?? ZenMuxAPIError.emptyResponse.localizedDescription
            )
            return
        }
        let document = XBookmarkMarkdownExporter.classifiedDocument(
            report: report,
            itemCount: items.count
        )
        collectionSession.document = document
        tab.xBookmarkDigestState = .completed(count: items.count)
        showXBookmarkDocument(document, for: tab)
    }

    @MainActor
    private func showXBookmarkDocument(_ document: XBookmarkMarkdownDocument, for tab: Tab) {
        let controller = tab.xBookmarkArchiveWindowController ?? XBookmarkArchiveWindowController()
        tab.xBookmarkArchiveWindowController = controller
        controller.show(document)
    }

    /// Opens the native AI sidebar and immediately creates a structured digest
    /// for the focused YouTube video. The existing ZenMux page-context path
    /// owns transcript retrieval and audiovisual fallback, so this entry does
    /// not introduce a second video-processing or credential stack.
    @MainActor
    func startYouTubeDigest() {
        let aiEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
        guard let tab = focusingTab,
              Self.shouldOfferYouTubeDigest(
                pageURL: tab.url,
                isAIEnabled: aiEnabled,
                isIncognito: isIncognito,
                isOverviewActive: groupOverviewState != nil,
                isChatAvailable: tab.aiChatEnabled
              ) else {
            NSSound.beep()
            return
        }

        let session = zenMuxChatSession(for: tab)
        session.draft = ZenMuxChatSession.youtubeDigestDraft()
        tab.updateFocusTarget(.aiChat)
        prepareAIChatSidebarOpen(trigger: .button)
        setAIChatCollapsed(for: tab, collapsed: false)
        session.requestFocus()

        guard !session.isSending,
              ((try? ZenMuxCredentialStore.shared.loadAPIKey()) ?? nil) != nil else {
            return
        }

        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            var context = ZenMuxPageContext(title: tab.title, url: tab.url)
            if let provider = tab.webContentWrapper as? PageContentProviding {
                context.pageContent = await provider.pageContentContext()
            }
            await session.send(
                pageContext: context,
                browserAutomation: { [weak tab] action in
                    guard let provider = tab?.webContentWrapper as? BrowserAutomationProviding else {
                        return BrowserAutomationResult(
                            succeeded: false,
                            message: "This tab does not provide browser automation."
                        )
                    }
                    return await provider.performBrowserAutomation(action)
                },
                googleSearch: { [weak self] query in
                    await self?.collectZenMuxGoogleSearchResults(query: query) ?? []
                }
            )
        }
    }

    func onAIEnabledChanged(_ enabled: Bool, sentinelOnLogin: Bool) {
        _ = sentinelOnLogin
        Task {
            await SentinelHelper.unregister()
        }
        // ZenMux is the only AI provider. Keep the legacy scheduled-agent
        // process stopped regardless of the native chat toggle.
        MainActor.assumeIsolated { SentinelWatchdog.shared.stop() }
        SentinelHelper.requestTerminationForBrowserUpdate()
        if !enabled {
            closeAllAIContent()
        }
    }

    /// Re-asserts the disabled half of the AI toggle as a window comes up.
    ///
    /// `updateAISettings` only reacts to an edge, and `lastPhiAIEnabled` is
    /// seeded from the preference the window is born with. Guest entry turns
    /// AI off before the first window materializes, so that edge lands with no
    /// BrowserState listening and the one created afterwards sees no change —
    /// leaving the Phi extensions loaded for the whole session.
    ///
    /// Only the disabled half needs re-asserting: `ExtensionsProxy::Init`
    /// already re-enables the Phi extensions when the Mac-side toggle is on.
    /// The side effects of `onAIEnabledChanged` (Sentinel teardown and AI
    /// content teardown) belong to the toggle's edge and are deliberately not
    /// repeated per window.
    ///
    /// Deferred one runloop turn: on the ordinary window path this runs inside
    /// `Browser::Create`, before the owning window controller finished
    /// construction and registered itself. Disabling extensions there would
    /// re-enter the Mac side with registry change events for a window that is
    /// not yet addressable.
    func syncPhiExtensionsIfAIDisabled() {
        // The ZenMux chat does not use the private AI extension. Do not toggle
        // the framework's extension bundle here because non-AI browser
        // features, including Reader View, have their own lifecycle in it.
    }

    /// Only called when AI is enabled.
    func updateSentinelRegistration(_ launchOnLogin: Bool) {
        MainActor.assumeIsolated {
            AuthenticatedSentinelSessionLifecycle.reconcile(
                aiEnabled:
                    PhiPreferences.AISettings.phiAIEnabled.loadValue(),
                launchOnLogin: launchOnLogin
            )
        }
    }

    func closeAllAIContent() {
        for tab in tabs {
            tab.toggleAIChat(true)
        }
        aiChatCollapsed = true

        let aiTabsSnapshot = aiChatTabs
        aiChatTabs.removeAll()
        removeAllZenMuxChatSessions()
        for (_, aiTab) in aiTabsSnapshot {
            aiTab.webContentWrapper?.close()
        }

        let conversationTabs = tabs.filter { tab in
            guard let url = tab.url else { return false }
            return url.hasPrefix("chrome://conversation") || url.hasPrefix("phi://conversation")
        }

        guard !conversationTabs.isEmpty else { return }

        let nonConversationCount = tabs.count - conversationTabs.count
        if nonConversationCount == 0 {
            createTab("chrome://newtab", focusAfterCreate: true)
        }

        for tab in conversationTabs {
            tab.webContentWrapper?.close()
        }
    }
}
