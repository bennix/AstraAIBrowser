// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import PostHog

@MainActor
enum FeatureEntryAnalytics {
    enum Button: String, CaseIterable {
        case chat
        case memory
        case download
        case youtubeDigest = "youtube_digest"
        case xBookmarkDigest = "x_bookmark_digest"
        case organizeTabs = "organize_tabs"
    }

    enum Surface: String, CaseIterable {
        case sidebar
        case webContentHeader = "web_content_header"
    }

    static func capture(_ button: Button, surface: Surface) {
        PostHogSDK.shared.capture("feature_entry_tapped", properties: [
            "button": button.rawValue,
            "surface": surface.rawValue,
        ])
    }
}

/// State model for the sidebar bottom bar.
class SidebarBottomBarState: ObservableObject {
    /// Single-row height.
    static let singleRowHeight: CGFloat = 24
    /// Two-row height.
    static let doubleRowHeight: CGFloat = 54
    /// Spacing between the two rows.
    static let rowSpacing: CGFloat = 6
    
    /// Legacy compact layout flag, kept for compatibility.
    @Published var isCompact: Bool = false
    
    /// Whether the feedback button is hidden for the current access mode.
    @Published var isFeedbackHidden: Bool = ApplicationState.shared.isGuest
    
    /// Current bar height.
    var currentHeight: CGFloat {
        isCompact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    
    func height(for compact: Bool) -> CGFloat {
        return compact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    /// Whether the chat button is hidden.
    @Published var isChatHidden: Bool = false

    /// Whether the AI memory button is hidden (mirrors the global Phi AI toggle).
    @Published var isMemoryHidden: Bool = false

    /// Whether the downloads popover is visible.
    @Published var isDownloadPopoverShown: Bool = false

    /// Whether the contextual YouTube digest entry is hidden.
    @Published var isYouTubeDigestHidden: Bool = true

    /// Whether the contextual X bookmark digest entry is hidden.
    @Published var isXBookmarkDigestHidden: Bool = true

    /// Whether the X bookmark collection controls are visible.
    @Published var isXBookmarkDigestPopoverShown: Bool = false

    @Published var xBookmarkDigestState: XBookmarkDigestState = .inactive

    /// Whether the focused X tab is displaying its bookmarks timeline.
    @Published var isXBookmarksPage: Bool = false

    /// Whether immersive translation is unavailable for the focused page.
    @Published var isImmersiveTranslationHidden: Bool = true

    /// Whether the immersive translation controls are visible.
    @Published var isImmersiveTranslationPopoverShown: Bool = false

    @Published var immersiveTranslationState: ImmersiveTranslationState = .inactive

    @Published var immersiveTranslationLanguage = ImmersiveTranslationPreferences.loadLanguage() {
        didSet { ImmersiveTranslationPreferences.saveLanguage(immersiveTranslationLanguage) }
    }

    @Published var immersiveTranslationProvider = ImmersiveTranslationPreferences.loadProvider() {
        didSet { ImmersiveTranslationPreferences.saveProvider(immersiveTranslationProvider) }
    }
}

/// SwiftUI implementation of the sidebar bottom bar.
struct SidebarBottomBarSwiftUI: View {
    @ObservedObject var state: SidebarBottomBarState
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    @ObservedObject var cardManager: NotificationCardManager
    
    let onFeedbackTap: () -> Void
    let onBookmarkTap: () -> Void
    let onChatTap: () -> Void
    let onCardEntryTap: () -> Void
    let onMemoryTap: () -> Void
    let onDownloadTap: () -> Void
    let onYouTubeDigestTap: () -> Void
    let onXBookmarkDigestTap: () -> Void
    let onXBookmarkDigestStop: () -> Void
    let onImmersiveTranslationTap: (
        ImmersiveTranslationLanguage,
        ImmersiveTranslationProvider
    ) -> Void
    
    var body: some View {
        regularLayout
            .frame(height: SidebarBottomBarState.singleRowHeight)
    }
    
    // MARK: - Regular Layout
    
    private var regularLayout: some View {
        HStack(spacing: 4) {
            downloadButton

            memoryButton

            cardEntryButton

            immersiveTranslationButton

            xBookmarkDigestButton

            if !state.isYouTubeDigestHidden {
                YouTubeDigestButton(action: onYouTubeDigestTap)
            }

            Spacer(minLength: 0)

            if !state.isFeedbackHidden {
                ViewThatFits(in: .horizontal) {
                    FeedbackButtonSwiftUI(action: onFeedbackTap)
                    FeedbackButtonSwiftUI(action: onFeedbackTap, isIconOnly: true)
                }
                .layoutPriority(1)
            }

            if !state.isChatHidden {
                ChatButton(action: onChatTap)
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, WebContentConstant.edgesSpacing)
    }

    @ViewBuilder
    private var memoryButton: some View {
        if !state.isMemoryHidden {
            MemoryButton(action: onMemoryTap)
        }
    }

    @ViewBuilder
    private var immersiveTranslationButton: some View {
        if !state.isImmersiveTranslationHidden {
            Button {
                state.isImmersiveTranslationPopoverShown.toggle()
            } label: {
                Group {
                    if state.immersiveTranslationState == .translating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(translationButtonColor)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString(
                "sidebar.immersiveTranslationButton.tooltip",
                value: "Immersive translation",
                comment: "Sidebar - Tooltip for the immersive translation button"
            ))
            .popover(isPresented: $state.isImmersiveTranslationPopoverShown, arrowEdge: .top) {
                ImmersiveTranslationPopover(
                    translationState: $state.immersiveTranslationState,
                    language: $state.immersiveTranslationLanguage,
                    provider: $state.immersiveTranslationProvider,
                    onTranslate: onImmersiveTranslationTap
                )
            }
        }
    }

    private var translationButtonColor: Color {
        if case .active = state.immersiveTranslationState {
            return .accentColor
        }
        return .primary
    }

    @ViewBuilder
    private var xBookmarkDigestButton: some View {
        if !state.isXBookmarkDigestHidden {
            Button {
                state.isXBookmarkDigestPopoverShown.toggle()
            } label: {
                Group {
                    if state.xBookmarkDigestState.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bookmark.square")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString(
                "browser.xBookmarkArchiveButton.tooltip",
                value: "X bookmark archive",
                comment: "Browser chrome - Tooltip for the contextual X bookmark archive button"
            ))
            .popover(isPresented: $state.isXBookmarkDigestPopoverShown, arrowEdge: .top) {
                XBookmarkDigestPopover(
                    digestState: $state.xBookmarkDigestState,
                    isBookmarksPage: state.isXBookmarksPage,
                    onRun: onXBookmarkDigestTap,
                    onStop: onXBookmarkDigestStop
                )
            }
        }
    }
    
    // MARK: - Download Button
    
    @ViewBuilder
    private var downloadButton: some View {
        DownloadButtonView(
            viewModel: downloadViewModel,
            onTap: {
                onDownloadTap()
                state.isDownloadPopoverShown.toggle()
            }
        )
        .popover(isPresented: $state.isDownloadPopoverShown, arrowEdge: .top) {
            if let manager = downloadViewModel.downloadsManager {
                DownloadsListView(downloadsManager: manager)
                    .frame(width: 340, height: 317)
            }
        }
    }
    
    // MARK: - Legacy Compact Layout
    
    private var compactLayout: some View {
        VStack(spacing: SidebarBottomBarState.rowSpacing) {
            HStack(spacing: 2) {
                downloadButton

                memoryButton

                cardEntryButton

                Spacer()

                if !state.isChatHidden {
                    ChatButton(action: onChatTap)
                }
            }
            .padding(.leading, WebContentConstant.edgesSpacing)
            .frame(height: SidebarBottomBarState.singleRowHeight)
            .animation(showCardEntry ? .spring(response: 0.28, dampingFraction: 0.78) : nil, value: showCardEntry)
            
            if !state.isFeedbackHidden {
                FeedbackButtonSwiftUI(action: onFeedbackTap, isIconOnly: false)
                    .padding(.leading, 8)
                    .frame(height: SidebarBottomBarState.singleRowHeight)
            }
        }
    }

    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }

    @ViewBuilder
    private var cardEntryButton: some View {
        if showCardEntry {
            CardEntryButton(action: onCardEntryTap)
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .identity
                    )
                )
        }
    }
}

struct ImmersiveTranslationPopover: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var translationState: ImmersiveTranslationState
    @Binding var language: ImmersiveTranslationLanguage
    @Binding var provider: ImmersiveTranslationProvider
    let onTranslate: (ImmersiveTranslationLanguage, ImmersiveTranslationProvider) -> Void

    private var isBusy: Bool { translationState == .translating }

    private var isActive: Bool {
        if case .active = translationState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString(
                "translation.popover.title",
                value: "Immersive Translation",
                comment: "Immersive translation - Popover title"
            ))
            .font(.headline)

            Picker(
                NSLocalizedString(
                    "translation.popover.targetLanguage",
                    value: "Translate to",
                    comment: "Immersive translation - Target language picker label"
                ),
                selection: $language
            ) {
                ForEach(ImmersiveTranslationLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .disabled(isBusy || isActive)

            if !isActive {
                Text(NSLocalizedString(
                    "translation.popover.zenMuxPrivacyNotice",
                    value: "ZenMux enhanced translation sends the selected page text to your configured model.",
                    comment: "Immersive translation - Privacy notice for ZenMux translation"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let message) = translationState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                dismiss()
                onTranslate(
                    language,
                    provider
                )
            } label: {
                HStack {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(actionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            Button {
                dismiss()
                VocabularyBookWindowController.shared.show()
            } label: {
                Label(
                    NSLocalizedString(
                        "translation.popover.openVocabularyBookAction",
                        value: "Vocabulary Book",
                        comment: "Immersive translation - Button in the translation popover that opens the saved words window"
                    ),
                    systemImage: "character.book.closed"
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var actionTitle: String {
        if isActive {
            return NSLocalizedString(
                "translation.popover.showOriginalAction",
                value: "Show original",
                comment: "Immersive translation - Remove translations action"
            )
        }
        return NSLocalizedString(
            "translation.popover.translateAction",
            value: "Translate page",
            comment: "Immersive translation - Start translation action"
        )
    }
}

struct XBookmarkDigestPopover: View {
    @Binding var digestState: XBookmarkDigestState
    let isBookmarksPage: Bool
    let onRun: () -> Void
    let onStop: () -> Void

    private var isSummarizing: Bool {
        if case .summarizing = digestState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString(
                "xBookmarks.popover.title",
                value: "X Bookmark Archive",
                comment: "X bookmark digest - Popover title"
            ))
            .font(.headline)

            Text(NSLocalizedString(
                "xBookmarks.popover.collectionNotice",
                value: "Astra uses the current signed-in X tab, opens no background tabs, and collects post text, links, quoted text, and images. Videos are never downloaded; only their post links are kept.",
                comment: "X bookmark digest - Explanation of the local automatic collection stage"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(NSLocalizedString(
                "xBookmarks.popover.zenMuxNotice",
                value: "Collected content stays local unless you choose ZenMux classification when stopping or finishing. You can always keep a raw Markdown archive without AI.",
                comment: "X bookmark digest - Privacy notice explaining that ZenMux classification is optional"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            statusView

            Button(action: onRun) {
                HStack {
                    if digestState.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(actionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSummarizing)

            if canStop {
                Button(action: onStop) {
                    Text(NSLocalizedString(
                        "xBookmarks.popover.stopAndFinishAction",
                        value: "Stop and create archive…",
                        comment: "X bookmark digest - Button stopping collection and asking how to create a Markdown archive"
                    ))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private var statusView: some View {
        if !isBookmarksPage, digestState == .inactive {
            Text(NSLocalizedString(
                "xBookmarks.popover.openBookmarksStatus",
                value: "Astra will open your X bookmarks and start collecting automatically.",
                comment: "X bookmark digest - Status shown before automatic collection starts from another X page"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch digestState {
            case .inactive:
                Text(NSLocalizedString(
                    "xBookmarks.popover.readyStatus",
                    value: "Ready. Collection starts from the newest bookmark and continues to the oldest.",
                    comment: "X bookmark digest - Status shown before collection starts"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            case .collecting(let count):
                Text(String(
                    format: NSLocalizedString(
                        "xBookmarks.popover.collectingStatus",
                        value: "Collected %ld posts…",
                        comment: "X bookmark digest - Live collection status; placeholder is the unique post count"
                    ),
                    count
                ))
                .font(.caption)
            case .paused(let count):
                Text(String(
                    format: NSLocalizedString(
                        "xBookmarks.popover.pausedStatus",
                        value: "Paused with %ld posts collected. Continue from this position or finish the archive now.",
                        comment: "X bookmark digest - Paused collection status; placeholder is the unique post count"
                    ),
                    count
                ))
                .font(.caption)
            case .ready(let count):
                Text(String(
                    format: NSLocalizedString(
                        "xBookmarks.popover.readyForArchiveStatus",
                        value: "Collection finished with %ld posts. Choose the Markdown output.",
                        comment: "X bookmark digest - Status after the oldest bookmark is reached; placeholder is the unique post count"
                    ),
                    count
                ))
                .font(.caption)
                .foregroundStyle(.green)
            case .summarizing(let count):
                Text(String(
                    format: NSLocalizedString(
                        "xBookmarks.popover.summarizingStatus",
                        value: "Collected %ld posts. ZenMux is classifying them…",
                        comment: "X bookmark digest - Status shown during AI classification; placeholder is the collected post count"
                    ),
                    count
                ))
                .font(.caption)
            case .completed(let count):
                Text(String(
                    format: NSLocalizedString(
                        "xBookmarks.popover.completedStatus",
                        value: "%ld posts are available in the Markdown archive.",
                        comment: "X bookmark digest - Completion status; placeholder is the archived post count"
                    ),
                    count
                ))
                .font(.caption)
                .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionTitle: String {
        if !isBookmarksPage, digestState == .inactive {
            return NSLocalizedString(
                "xBookmarks.popover.openBookmarksAction",
                value: "Start bookmark archive",
                comment: "X bookmark digest - Button that opens the bookmarks timeline and starts automatic collection"
            )
        }
        switch digestState {
        case .collecting:
            return NSLocalizedString(
                "xBookmarks.popover.pauseAction",
                value: "Pause collection",
                comment: "X bookmark digest - Button pausing automatic timeline collection without discarding posts"
            )
        case .paused:
            return NSLocalizedString(
                "xBookmarks.popover.continueAction",
                value: "Continue collection",
                comment: "X bookmark digest - Button resuming automatic timeline collection from its saved position"
            )
        case .ready:
            return NSLocalizedString(
                "xBookmarks.popover.createArchiveAction",
                value: "Create Markdown archive…",
                comment: "X bookmark digest - Button choosing between classified and raw Markdown after collection"
            )
        case .summarizing:
            return NSLocalizedString(
                "xBookmarks.popover.summarizingAction",
                value: "Summarizing…",
                comment: "X bookmark digest - Disabled button title while ZenMux prepares the report"
            )
        case .inactive:
            return NSLocalizedString(
                "xBookmarks.popover.startAction",
                value: "Start bookmark archive",
                comment: "X bookmark digest - Button that starts automatic timeline collection"
            )
        case .completed:
            return NSLocalizedString(
                "xBookmarks.popover.runAgainAction",
                value: "View Markdown archive",
                comment: "X bookmark digest - Button reopening the completed Markdown archive"
            )
        case .failed:
            return NSLocalizedString(
                "xBookmarks.popover.retryAction",
                value: "Retry",
                comment: "X bookmark digest - Button that retries after collection or summarization fails"
            )
        }
    }

    private var canStop: Bool {
        switch digestState {
        case .collecting, .paused:
            return true
        case .inactive, .ready, .summarizing, .completed, .failed:
            return false
        }
    }
}

// MARK: - Feedback Button

struct FeedbackButtonSwiftUI: View {
    let action: () -> Void
    /// Whether to render the icon-only variant.
    var isIconOnly: Bool = false
    var contentWidth: CGFloat? = nil
    var contentHeight: CGFloat? = nil
    
    /// Width for icon-only mode.
    private let iconOnlyWidth: CGFloat = 32
    /// Width for the full label mode.
    private let fullWidth: CGFloat = 90
    /// Minimum horizontal breathing room for the full label mode.
    private let fullContentHorizontalPadding: CGFloat = 2
    
    @State private var isHovering = false
    
    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: NSImage(resource: .sidebarFeedback))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .themedTint(.textPrimary)
                
                if !isIconOnly {
                    Text(NSLocalizedString("sidebar.feedbackButton.title", value: "Feedback", comment: "Feedback - Sidebar feedback button title"))
                        .font(.system(size: 11))
                        .foregroundColor(Color.primaryLabel)
                        .lineLimit(1)
                        .fixedSize(horizontal: contentWidth == nil, vertical: false)
                }
            }
            .padding(.horizontal, isIconOnly ? 0 : fullContentHorizontalPadding)
            .frame(width: isIconOnly ? iconOnlyWidth : contentWidth)
            .frame(minWidth: !isIconOnly && contentWidth == nil ? fullWidth : nil)
            .padding(.vertical, 3)
            .frame(height: contentHeight)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(Color.commonBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("sidebar.feedbackButton.tooltip", value: "Feedback", comment: "Feedback - Tooltip text for feedback button"))
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let image: NSImage
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - YouTube Digest Button

struct YouTubeDigestButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(
            "sidebar.youtubeDigestButton.tooltip",
            value: "Summarize this YouTube video",
            comment: "Sidebar - Tooltip for the contextual YouTube video digest button"
        ))
        .accessibilityLabel(NSLocalizedString(
            "sidebar.youtubeDigestButton.accessibilityLabel",
            value: "YouTube video digest",
            comment: "Sidebar - Accessibility label for the contextual YouTube video digest button"
        ))
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Card Entry Button

struct CardEntryButton: View {
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPopping = false

    private let buttonSize: CGFloat = 24
    private let cornerRadius: CGFloat = 6
    private let popScale: CGFloat = 1.18
    private let popDelay: TimeInterval = 0.22
    private let popUpDuration: TimeInterval = 0.12
    private let popDownDuration: TimeInterval = 0.18

    var body: some View {
        Button(action: action) {
            Image(.cardBulbIcon)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPopping ? popScale : 1)
        .onAppear {
            isPopping = false
            DispatchQueue.main.asyncAfter(deadline: .now() + popDelay) {
                withAnimation(.easeOut(duration: popUpDuration)) {
                    isPopping = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + popUpDuration) {
                    withAnimation(.easeInOut(duration: popDownDuration)) {
                        isPopping = false
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - NSView Bridge

/// AppKit bridge for the SwiftUI sidebar bottom bar.
class SidebarBottomBarSwiftUIView: NSView {
    private var hostingView: ThemedHostingView?
    private let state = SidebarBottomBarState()
    private let downloadViewModel = DownloadButtonViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var heightConstraint: NSLayoutConstraint?
    
    /// Height change callback.
    var onHeightChange: ((CGFloat) -> Void)?
    
    /// Button callbacks.
    var onFeedbackTap: (() -> Void)?
    var onBookmarkTap: (() -> Void)?
    var onChatTap: (() -> Void)?
    var onCardEntryTap: (() -> Void)?
    var onMemoryTap: (() -> Void)?
    var onDownloadTap: (() -> Void)?
    var onYouTubeDigestTap: (() -> Void)?
    var onXBookmarkDigestTap: (() -> Void)?
    var onXBookmarkDigestStop: (() -> Void)?
    var onImmersiveTranslationTap: ((
        ImmersiveTranslationLanguage,
        ImmersiveTranslationProvider
    ) -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
        setupObservers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingView()
        setupObservers()
    }
    
    private func setupHostingView() {
        let hosting = ThemedHostingView(
            rootView: SidebarBottomBarSwiftUI(
                state: state,
                downloadViewModel: downloadViewModel,
                cardManager: NotificationCardManager.shared,
                onFeedbackTap: { [weak self] in self?.onFeedbackTap?() },
                onBookmarkTap: { [weak self] in self?.onBookmarkTap?() },
                onChatTap: { [weak self] in self?.onChatTap?() },
                onCardEntryTap: { [weak self] in self?.onCardEntryTap?() },
                onMemoryTap: { [weak self] in self?.onMemoryTap?() },
                onDownloadTap: { [weak self] in self?.onDownloadTap?() },
                onYouTubeDigestTap: { [weak self] in self?.onYouTubeDigestTap?() },
                onXBookmarkDigestTap: { [weak self] in self?.onXBookmarkDigestTap?() },
                onXBookmarkDigestStop: { [weak self] in self?.onXBookmarkDigestStop?() },
                onImmersiveTranslationTap: { [weak self] language, provider in
                    self?.onImmersiveTranslationTap?(language, provider)
                }
            )
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        self.hostingView = hosting
    }
    
    private func setupObservers() {
        // Propagate compact-mode height changes to the container.
        state.$isCompact
            .removeDuplicates()
            .sink { [weak self] isCompact in
                guard let self = self else { return }
                self.onHeightChange?(self.state.height(for: isCompact))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .browserAccessStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.state.isFeedbackHidden = ApplicationState.shared.isGuest
            }
            .store(in: &cancellables)
    }
    
    /// Hides or shows the chat button, for example in private mode.
    func setChatHidden(_ hidden: Bool) {
        state.isChatHidden = hidden
    }

    /// Hides or shows the AI memory button. Should be hidden when Phi AI is disabled.
    func setMemoryHidden(_ hidden: Bool) {
        state.isMemoryHidden = hidden
    }

    /// Hides or shows the contextual YouTube video digest entry.
    func setYouTubeDigestHidden(_ hidden: Bool) {
        state.isYouTubeDigestHidden = hidden
    }

    func setXBookmarkDigestHidden(_ hidden: Bool) {
        state.isXBookmarkDigestHidden = hidden
        if hidden {
            state.isXBookmarkDigestPopoverShown = false
        }
    }

    func setXBookmarkDigestState(_ digestState: XBookmarkDigestState) {
        state.xBookmarkDigestState = digestState
    }

    func setXBookmarksPage(_ isBookmarksPage: Bool) {
        state.isXBookmarksPage = isBookmarksPage
    }

    func setImmersiveTranslationHidden(_ hidden: Bool) {
        state.isImmersiveTranslationHidden = hidden
        if hidden {
            state.isImmersiveTranslationPopoverShown = false
        }
    }

    func setImmersiveTranslationState(_ translationState: ImmersiveTranslationState) {
        state.immersiveTranslationState = translationState
    }
    
    /// Binds the downloads manager for progress display.
    func bindDownloadsManager(_ manager: DownloadsManager) {
        downloadViewModel.bindTo(manager)
    }
    
    /// Current rendered bar height.
    var currentHeight: CGFloat {
        state.currentHeight
    }
}
