// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

final class NewTabViewController: NSViewController {
    private enum InputMode: Int {
        case ai
        case google
        case url
    }

    private let browserState: BrowserState
    private weak var currentTab: Tab?
    private var cancellables = Set<AnyCancellable>()

    private let iconSize = NSSize(width: 64, height: 64)
    private let contentSpacing: CGFloat = 40
    private let collapsedOmniBoxHeight: CGFloat = 57
    private var areControlsHidden = false
    private var keyDownMonitor: Any?

    private lazy var omniBoxController: OmniBoxViewController = {
        let controller = OmniBoxViewController(viewModel: .init(windowState: browserState), state: browserState)
        controller.setActionDelegate(self)
        return controller
    }()

    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        return scrollView
    }()

    private let contentView = NSView()

    private lazy var iconImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = NSApp.applicationIconImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        return imageView
    }()
    
    private lazy var incognitoLabel: NSTextField = {
        let tf = NSTextField()
        tf.stringValue = NSLocalizedString("browser.newTabPage.incognitoLabel", value: "Incognito", comment: "Incognito label in the native new tab page")
        tf.font = NSFont(name: "IvyPrestoHeadline-Light", size: 21)
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.alignment = .center
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byClipping
        tf.maximumNumberOfLines = 1
        tf.textColor = .primaryLabel
        tf.allowsDefaultTighteningForTruncation = false
        return tf
    }()

    private lazy var inputModeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: [
                NSLocalizedString(
                    "browser.newTabPage.inputMode.ai",
                    value: "AI",
                    comment: "New tab page - Unified input mode that sends the text to ZenMux"
                ),
                NSLocalizedString(
                    "browser.newTabPage.inputMode.google",
                    value: "Google",
                    comment: "New tab page - Unified input mode that searches with Google"
                ),
                NSLocalizedString(
                    "browser.newTabPage.inputMode.url",
                    value: "URL",
                    comment: "New tab page - Unified input mode that opens a website address"
                ),
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(inputModeDidChange(_:))
        )
        control.controlSize = .small
        control.selectedSegment = InputMode.google.rawValue
        control.setEnabled(!browserState.isIncognito, forSegment: InputMode.ai.rawValue)
        return control
    }()

    init(state: BrowserState) {
        self.browserState = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopKeyboardMonitoring()
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.contentOverlayBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupObservers()
        applySelectedInputMode()
        updateContentLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startKeyboardMonitoring()
        omniBoxController.focusTextField()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopKeyboardMonitoring()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentLayout()
    }

    func updateForTab(_ tab: Tab?) {
        currentTab = tab
        setNativeControlsHidden(false)
        omniBoxController.setCurrentTabForNavigation(tab)
    }

    /// Restores the NTP to its initial clean state — native controls visible and
    /// the omnibox cleared — after a navigation that started here was routed to
    /// another Space and cancelled. Submitting from the omnibox hid the controls
    /// (`omniBoxDidClear`) and can leave the typed text behind; this brings the
    /// clean new-tab page back. `updateForTab` alone does NOT clear the omnibox.
    func resetToInitialState(for tab: Tab?) {
        omniBoxController.reset()
        setNativeControlsHidden(false)
        omniBoxController.setCurrentTabForNavigation(tab)
    }

    func focusOmnibox() {
        omniBoxController.focusTextField()
    }
    
    private func setNativeControlsHidden(_ hidden: Bool) {
        guard areControlsHidden != hidden else { return }
        areControlsHidden = hidden
        iconImageView.isHidden = hidden
        omniBoxController.view.isHidden = hidden
        incognitoLabel.isHidden = hidden || !browserState.isIncognito
        inputModeControl.isHidden = hidden
    }

    private func setupViews() {
        view.addSubview(scrollView)
        scrollView.documentView = contentView

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        addChild(omniBoxController)
        contentView.addSubview(iconImageView)
        contentView.addSubview(incognitoLabel)
        contentView.addSubview(inputModeControl)
        contentView.addSubview(omniBoxController.view)

        incognitoLabel.isHidden = !browserState.isIncognito

        omniBoxController.view.translatesAutoresizingMaskIntoConstraints = true
        omniBoxController.view.autoresizingMask = []
    }

    private func setupObservers() {
        omniBoxController.$contentSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateContentLayout()
            }
            .store(in: &cancellables)
    }

    @objc private func inputModeDidChange(_ sender: NSSegmentedControl) {
        applySelectedInputMode()
        omniBoxController.focusTextField()
    }

    private func applySelectedInputMode() {
        guard let mode = InputMode(rawValue: inputModeControl.selectedSegment) else { return }
        let placeholder: String
        switch mode {
        case .ai:
            placeholder = NSLocalizedString(
                "browser.newTabPage.inputPlaceholder.ai",
                value: "Ask ZenMux",
                comment: "New tab page - Placeholder shown when the unified input sends a question to ZenMux"
            )
        case .google:
            placeholder = NSLocalizedString(
                "browser.newTabPage.inputPlaceholder.google",
                value: "Search Google",
                comment: "New tab page - Placeholder shown when the unified input searches with Google"
            )
        case .url:
            placeholder = NSLocalizedString(
                "browser.newTabPage.inputPlaceholder.url",
                value: "Enter URL",
                comment: "New tab page - Placeholder shown when the unified input opens a website address"
            )
        }

        omniBoxController.configureSubmission(placeholder: placeholder) { [weak self] input, commandKeyPressed in
            self?.submit(input, mode: mode, commandKeyPressed: commandKeyPressed) ?? true
        }
    }

    private func submit(
        _ input: String,
        mode: InputMode,
        commandKeyPressed: Bool
    ) -> Bool {
        switch mode {
        case .ai:
            submitToZenMux(input)
            return true
        case .google:
            if !omniBoxController.submitGoogleSearch(commandKeyPressed: commandKeyPressed) {
                NSSound.beep()
            }
            return true
        case .url:
            if !omniBoxController.submitURL(commandKeyPressed: commandKeyPressed) {
                NSSound.beep()
            }
            return true
        }
    }

    private func submitToZenMux(_ input: String) {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let tab = currentTab else {
            NSSound.beep()
            return
        }

        let session = browserState.zenMuxChatSession(for: tab)
        session.draft = question
        tab.updateFocusTarget(.aiChat)
        if tab.aiChatCollapsed {
            browserState.prepareAIChatSidebarOpen(trigger: .button)
            browserState.setAIChatCollapsed(for: tab, collapsed: false)
        }
        session.requestFocus()
        omniBoxController.reset()

        guard ((try? ZenMuxCredentialStore.shared.loadAPIKey()) ?? nil) != nil else {
            return
        }

        Task { @MainActor in
            await session.send(
                pageContext: ZenMuxPageContext(title: tab.title, url: tab.url)
            )
            session.requestFocus()
        }
    }

    private func startKeyboardMonitoring() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func stopKeyboardMonitoring() {
        guard let keyDownMonitor else { return }
        NSEvent.removeMonitor(keyDownMonitor)
        self.keyDownMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard shouldHandleKeyboardEvent(event) else { return event }

        let isCommandKeyPressed = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76

        guard isCommandKeyPressed && isReturnKey else { return event }

        omniBoxController.confirmSelection(commandKeyPressed: true)
        return nil
    }

    private func shouldHandleKeyboardEvent(_ event: NSEvent) -> Bool {
        guard !areControlsHidden,
              let window = view.window,
              let eventWindow = event.window,
              eventWindow === window else {
            return false
        }
        return true
    }

    private func updateContentLayout() {
        guard isViewLoaded else { return }
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }
        // Fit the omnibox to the visible clip. Its natural width (the Cmd+L
        // panel's 680) overflows narrow surfaces — an NTP rendering inside a
        // splitview pane — which pushed the content column wider than the
        // clip: the icon then centered off into the hidden overflow and the
        // box ran edge-to-edge. Capping the width keeps the column within
        // the clip, so everything re-centers as the pane is resized.
        let omniNatural = omniBoxController.contentSize
        let omniHorizontalInset: CGFloat = 24
        let fittedOmniWidth = min(omniNatural.width,
                                  max(clipSize.width - omniHorizontalInset * 2, 240))
        let omniSize = NSSize(width: fittedOmniWidth, height: omniNatural.height)
        
        var labelSize = NSSize.zero
        if browserState.isIncognito {
            labelSize = incognitoLabel.cell?.cellSize ?? incognitoLabel.attributedStringValue.size()
            labelSize.width = ceil(labelSize.width) + 2
            labelSize.height = ceil(labelSize.height)
        }
        let labelSpacing: CGFloat = browserState.isIncognito ? 6 : 0
        let modeSize = inputModeControl.fittingSize
        let modeTopSpacing: CGFloat = 14
        let omniTopSpacing: CGFloat = 18

        let contentWidth = max(omniSize.width, iconSize.width, labelSize.width, modeSize.width)
        let contentHeight = iconSize.height + labelSpacing + labelSize.height
            + modeTopSpacing + modeSize.height + omniTopSpacing + omniSize.height
        let collapsedContentHeight = iconSize.height + labelSpacing + labelSize.height
            + modeTopSpacing + modeSize.height + omniTopSpacing + collapsedOmniBoxHeight

        let documentWidth = max(contentWidth, clipSize.width)
        let documentHeight = max(contentHeight, clipSize.height)
        contentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)

        let originX = (documentWidth - contentWidth) / 2
        let anchorTop = (clipSize.height + collapsedContentHeight) / 2
        let originY: CGFloat
        if contentHeight <= clipSize.height {
            originY = max(anchorTop - contentHeight, 0)
        } else {
            originY = 0
        }

        // Position icon at the top of our content column
        let iconX = originX + (contentWidth - iconSize.width) / 2
        let iconY = originY + contentHeight - iconSize.height
        iconImageView.frame = NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height)

        // Incognito keeps its explicit privacy label; regular windows omit it.
        let labelX = originX + (contentWidth - labelSize.width) / 2
        let labelY = iconImageView.frame.minY - labelSpacing - labelSize.height
        incognitoLabel.frame = NSRect(x: labelX, y: labelY, width: labelSize.width, height: labelSize.height)

        let modeX = originX + (contentWidth - modeSize.width) / 2
        let modeY = labelY - modeTopSpacing - modeSize.height
        inputModeControl.frame = NSRect(x: modeX, y: modeY, width: modeSize.width, height: modeSize.height)

        let omniX = originX + (contentWidth - omniSize.width) / 2
        let omniY = inputModeControl.frame.minY - omniTopSpacing - omniSize.height
        omniBoxController.view.frame = NSRect(x: omniX, y: omniY, width: omniSize.width, height: omniSize.height)

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

extension NewTabViewController: OmniBoxActionDelegate {
    func omniBoxDidClear() {
        setNativeControlsHidden(true)
        omniBoxController.reset()
    }
}
