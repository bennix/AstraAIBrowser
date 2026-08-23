// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import PostHog

struct AISettingView: View {
    @State private var showDisableAIAlert = false

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    private var aiEnabledBinding: Binding<Bool> {
        Binding(
            get: { phiAIEnabled },
            set: { newValue in
                if newValue {
                    phiAIEnabled = true
                } else {
                    showDisableAIAlert = true
                }
            }
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                AIMasterControlSection(
                    isOn: aiEnabledBinding,
                    enabled: true,
                    showsLoginPrompt: false,
                    loginAction: {}
                )
                ZenMuxConfigurationSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .onChange(of: phiAIEnabled) { _, newValue in
            // PostHog: Capture AI features toggled event
            PostHogSDK.shared.capture("ai_features_toggled", properties: [
                "enabled": newValue,
            ])
        }
        .alert(
            NSLocalizedString("settings.ai.disableFeatures.title", value: "Turn Off AI Features?",
                              comment: "AI settings - Confirmation alert title when disabling all AI features"),
            isPresented: $showDisableAIAlert
        ) {
            Button(NSLocalizedString("settings.ai.disableFeatures.confirmButton", value: "Turn Off",
                                     comment: "AI settings - Destructive button to confirm turning off AI features"),
                   role: .destructive) {
                phiAIEnabled = false
            }
            Button(NSLocalizedString("settings.ai.disableFeatures.cancelButton", value: "Cancel",
                                     comment: "AI settings - Cancel button in disable-AI confirmation alert"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.ai.disableFeatures.message", value: "ZenMux conversations will be closed.",
                                   comment: "AI settings - Alert message explaining that disabling AI closes ZenMux conversations"))
        }
    }
}

// MARK: - ZenMux

private struct ZenMuxConfigurationSectionView: View {
    private enum Status {
        case saved
        case testing
        case success
        case failure(String)
    }

    @State private var apiKey: String = (try? ZenMuxCredentialStore.shared.loadAPIKey()) ?? ""
    @State private var revealsAPIKey = false
    @State private var status: Status?

    @AppStorage(PhiPreferences.AISettings.zenMuxModelKey)
    private var modelRawValue = ZenMuxModel.geminiFlash.rawValue

    @AppStorage(PhiPreferences.AISettings.zenMuxInputLanguageKey)
    private var inputLanguageRawValue = ZenMuxInputLanguage.automatic.rawValue

    @AppStorage(PhiPreferences.AISettings.zenMuxResponseLanguageKey)
    private var responseLanguageRawValue = ZenMuxResponseLanguage.matchInput.rawValue

    private var selectedModel: ZenMuxModel {
        ZenMuxModel(rawValue: modelRawValue) ?? .geminiFlash
    }

    private var isTesting: Bool {
        if case .testing = status { return true }
        return false
    }

    var body: some View {
        AISectionView(
            title: NSLocalizedString(
                "settings.ai.zenMux.sectionTitle",
                value: "ZenMux models",
                comment: "AI settings - Section title for configuring the ZenMux model provider"
            ),
            subtitle: NSLocalizedString(
                "settings.ai.zenMux.description",
                value: "Use your own ZenMux key for multilingual AI chat. The key is encrypted on this Mac.",
                comment: "AI settings - Description of the ZenMux provider and local credential protection"
            )
        ) {
            AIContainerView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString(
                        "settings.ai.zenMux.apiKeyLabel",
                        value: "API key",
                        comment: "ZenMux AI settings - Label above the API key field"
                    ))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)

                    HStack(spacing: 8) {
                        Group {
                            if revealsAPIKey {
                                TextField("", text: $apiKey)
                            } else {
                                SecureField("", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(NSLocalizedString(
                            "settings.ai.zenMux.apiKeyAccessibilityLabel",
                            value: "ZenMux API key",
                            comment: "ZenMux AI settings - Accessibility label for the API key field"
                        ))

                        Button {
                            revealsAPIKey.toggle()
                        } label: {
                            Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealsAPIKey
                              ? NSLocalizedString(
                                "settings.ai.zenMux.hideAPIKeyTooltip",
                                value: "Hide API key",
                                comment: "ZenMux AI settings - Tooltip for hiding the API key"
                              )
                              : NSLocalizedString(
                                "settings.ai.zenMux.showAPIKeyTooltip",
                                value: "Show API key",
                                comment: "ZenMux AI settings - Tooltip for revealing the API key"
                              ))
                    }

                    HStack(spacing: 8) {
                        Button(NSLocalizedString(
                            "settings.ai.zenMux.saveButton",
                            value: "Save",
                            comment: "ZenMux AI settings - Button that encrypts and saves the API key"
                        ), action: saveAPIKey)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(NSLocalizedString(
                            "settings.ai.zenMux.testButton",
                            value: "Test API key",
                            comment: "ZenMux AI settings - Button that verifies the API key with ZenMux"
                        ), action: testAPIKey)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                        Spacer(minLength: 8)
                        statusView
                    }
                }
                .padding(.vertical, 12)

                Divider()

                zenMuxPickerRow(
                    title: NSLocalizedString(
                        "settings.ai.zenMux.modelTitle",
                        value: "Model",
                        comment: "ZenMux AI settings - Label for the model picker"
                    ),
                    selection: $modelRawValue
                ) {
                    ForEach(ZenMuxModel.allCases) { model in
                        Text("\(model.displayName) — \(model.rawValue)")
                            .tag(model.rawValue)
                    }
                }

                Divider()

                zenMuxPickerRow(
                    title: NSLocalizedString(
                        "settings.ai.zenMux.inputLanguageTitle",
                        value: "Input language",
                        comment: "ZenMux AI settings - Label for the language used to interpret user messages"
                    ),
                    selection: $inputLanguageRawValue
                ) {
                    ForEach(ZenMuxInputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }

                Divider()

                zenMuxPickerRow(
                    title: NSLocalizedString(
                        "settings.ai.zenMux.responseLanguageTitle",
                        value: "Response language",
                        comment: "ZenMux AI settings - Label for the preferred model response language"
                    ),
                    selection: $responseLanguageRawValue
                ) {
                    ForEach(ZenMuxResponseLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Text(NSLocalizedString(
                        "settings.ai.zenMux.noAccountPrompt",
                        value: "Need a ZenMux account or API key?",
                        comment: "ZenMux AI settings - Prompt shown before the ZenMux invitation link"
                    ))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)

                    Link(
                        NSLocalizedString(
                            "settings.ai.zenMux.invitationLink",
                            value: "Open invitation link",
                            comment: "ZenMux AI settings - Link that opens the ZenMux invitation page"
                        ),
                        destination: URL(string: "https://zenmux.ai/invite/GBQMC5")!
                    )
                    .font(.system(size: 12))
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .saved:
            Label(
                NSLocalizedString(
                    "settings.ai.zenMux.savedStatus",
                    value: "Saved securely",
                    comment: "ZenMux AI settings - Status shown after the encrypted API key is saved"
                ),
                systemImage: "lock.fill"
            )
            .foregroundStyle(.secondary)
        case .testing:
            ProgressView().controlSize(.small)
        case .success:
            Label(
                NSLocalizedString(
                    "settings.ai.zenMux.testSuccessStatus",
                    value: "Connection successful",
                    comment: "ZenMux AI settings - Status shown after a successful API key test"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .failure(let message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private func zenMuxPickerRow<Content: View>(
        title: String,
        selection: Binding<String>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 310, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    private func saveAPIKey() {
        do {
            try ZenMuxCredentialStore.shared.saveAPIKey(apiKey)
            status = .saved
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func testAPIKey() {
        status = .testing
        let candidate = apiKey
        let model = selectedModel
        Task { @MainActor in
            do {
                try await APIClient.shared.testZenMuxAPIKey(candidate, model: model)
                status = .success
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - AI Master Controls

private struct AIMasterControlSection: View {
    @Binding var isOn: Bool
    let enabled: Bool
    let showsLoginPrompt: Bool
    let loginAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLoginPrompt {
                GuestAILoginPromptRow(loginAction: loginAction)
            }

            AIEnableToggleRow(
                isOn: $isOn,
                enabled: enabled
            )
        }
    }
}

private struct GuestAILoginPromptRow: View {
    let loginAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(NSLocalizedString(
                "settings.ai.guestLoginPrompt.message",
                value: "Sign in to use AI features",
                comment: "AI settings - Message above the AI master toggle when Guest Mode requires sign-in"
            ))
            .font(.system(size: 13))
            .themedForeground(.textSecondary)

            Spacer(minLength: 12)

            Button(
                NSLocalizedString(
                    "settings.ai.guestLoginPrompt.loginButton",
                    value: "Sign in",
                    comment: "AI settings - Button in the Guest Mode AI prompt that opens sign-in"
                ),
                action: loginAction
            )
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
    }
}

// MARK: - AI Enable Toggle (top-level, no container)

private struct AIEnableToggleRow: View {
    @Binding var isOn: Bool
    let enabled: Bool

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { enabled ? isOn : false },
            set: { if enabled { isOn = $0 } }
        )
    }

    var body: some View {
        HStack {
            Text(NSLocalizedString("settings.ai.features.enableToggle", value: "Enable AI features in Astra Browser", comment: "AI settings - Master toggle to enable or disable all AI features in Astra Browser"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .opacity(enabled ? 1.0 : 0.4)
            Spacer(minLength: 12)
            Toggle("", isOn: effectiveBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .disabled(!enabled)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
    }
}

// MARK: - Browser Memory Section

private struct BrowserMemorySectionView: View {
    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.browserMemory.sectionTitle", value: "Browser memory", comment: "AI settings - Section title for browser memory management")
        ) {
            AIContainerView {
                AINavigationRow(
                    title: NSLocalizedString("settings.ai.browserMemory.manageButtonTitle", value: "View and manage your browser memory", comment: "AI settings - Row title to open browser memory management"),
                    enabled: enabled,
                    action: openBrowserMemoryPage
                )
            }
        }
    }

    private func openBrowserMemoryPage() {
        guard let state = BrowserState.currentState() else { return }
        state.createTab(
            "chrome://memory/memory.html",
            focusAfterCreate: true
        )
        FirstTimeActionTracker.capture(.memoryOpened)
    }
}

// MARK: - Phi Sentinel Section

private struct PhiSentinelSectionView: View {
    @AppStorage(PhiPreferences.AISettings.launchSentinelOnLogin.rawValue)
    private var launchSentinelOnLogin: Bool = PhiPreferences.AISettings.launchSentinelOnLogin.defaultValue

    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.phiSentinel.sectionTitle", value: "Astra Browser Sentinel", comment: "AI settings - Section title for Astra Browser Sentinel background helper"),
            subtitle: NSLocalizedString("settings.ai.phiSentinel.description", value: "Astra Browser Sentinel is a lightweight background helper that allows Astra Browser to complete scheduled AI tasks", comment: "AI settings - Description explaining what Astra Browser Sentinel does")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.phiSentinel.autoLaunchToggle", value: "Launch Astra Browser Sentinel when you sign in to your Mac", comment: "AI settings - Toggle to auto-launch Astra Browser Sentinel when signing in to the Mac"),
                    isOn: $launchSentinelOnLogin,
                    enabled: enabled
                )

                Divider()

                AINavigationRow(
                    title: NSLocalizedString("settings.ai.privateAI.title", value: "Private AI", comment: "AI settings - Row that opens Astra Browser Sentinel's Private AI page"),
                    enabled: enabled,
                    action: openPrivateAI
                )
            }
        }
        .onChange(of: launchSentinelOnLogin) {
            notifyNativeSettingsChanged()
        }
    }

    private func openPrivateAI() {
        SentinelHelper.openDashboard(section: "experimental")
    }
}

// MARK: - New Tab Page Section

private struct NewTabPageSectionView: View {
    @AppStorage(PhiPreferences.AISettings.enableProactiveSuggestionsOnNTP.rawValue)
    private var enableProactiveSuggestionsOnNTP: Bool = PhiPreferences.AISettings.enableProactiveSuggestionsOnNTP.defaultValue

    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.newTabPage.sectionTitle", value: "New Tab Page", comment: "AI settings - Section title for new tab page options")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.newTabPage.proactiveSuggestionsToggle", value: "Show proactive suggestions on the new tab page", comment: "AI settings - Toggle to show proactive suggestions on the new tab page"),
                    isOn: $enableProactiveSuggestionsOnNTP,
                    enabled: enabled
                )
            }
        }
        .onChange(of: enableProactiveSuggestionsOnNTP) {
            notifyNativeSettingsChanged()
        }
    }
}

// MARK: - AI Sidebar Section

private struct AISidebarSectionView: View {
    @AppStorage(PhiPreferences.AISettings.enableChatWithTabs.rawValue)
    private var enableChatWithTabs: Bool = PhiPreferences.AISettings.enableChatWithTabs.defaultValue

    let enabled: Bool

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.sidebar.sectionTitle", value: "AI Sidebar", comment: "AI settings - Section title for AI sidebar options")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.sidebar.includeCurrentTabToggle", value: "Automatically add current tab as context to new conversation", comment: "AI settings - Toggle to auto-add current tab as context when starting new AI conversation"),
                    isOn: $enableChatWithTabs,
                    enabled: enabled
                )
            }
        }
        .onChange(of: enableChatWithTabs) {
            notifyNativeSettingsChanged()
        }
    }
}

private struct ExternalConnectorsSectionView: View {
    @AppStorage(PhiPreferences.AISettings.enableConnectors.rawValue)
    private var enableConnectors: Bool = PhiPreferences.AISettings.enableConnectors.defaultValue

    @AppStorage(PhiPreferences.AISettings.enableConnectorContext.rawValue)
    private var enableConnectorContext: Bool = PhiPreferences.AISettings.enableConnectorContext.defaultValue

    @State private var showDisableConnectorsAlert = false

    let connectorViewModel: AISettingsConnectorViewModel
    let enabled: Bool

    private var subItemsEnabled: Bool { enabled && enableConnectors }

    private var connectorsEnabledBinding: Binding<Bool> {
        Binding(
            get: { enableConnectors },
            set: { newValue in
                if newValue {
                    enableConnectors = true
                } else {
                    showDisableConnectorsAlert = true
                }
            }
        )
    }

    var body: some View {
        AISectionView(
            title: NSLocalizedString("settings.ai.connectors.sectionTitle", value: "External Data Connectors", comment: "AI settings - Section title for external data connectors"),
            subtitle: NSLocalizedString("settings.ai.connectors.description", value: "External Data Connectors help to provide additional context for better AI experience", comment: "AI settings - Description explaining external data connectors purpose")
        ) {
            AIContainerView {
                AIToggleRow(
                    title: NSLocalizedString("settings.ai.connectors.enableToggle", value: "Enable External Data Connectors", comment: "AI settings - Toggle to enable external data connectors"),
                    isOn: connectorsEnabledBinding,
                    enabled: enabled
                )

                Divider()

                AIToggleRow(
                    title: NSLocalizedString("settings.ai.connectors.includeInNewConversationToggle", value: "Automatically add External Data Connectors as context to new conversation", comment: "AI settings - Toggle to auto-add connector data as context to new AI conversation"),
                    isOn: $enableConnectorContext,
                    enabled: subItemsEnabled
                )

                Divider()

                ConnectorsListView(connectorViewModel: connectorViewModel, enabled: subItemsEnabled)
            }
        }
        .onChange(of: enableConnectors) {
            notifyNativeSettingsChanged()
            if !enableConnectors {
                connectorViewModel.disconnectAll()
            }
        }
        .onChange(of: enableConnectorContext) {
            notifyNativeSettingsChanged()
        }
        .alert(
            NSLocalizedString("settings.ai.disableConnectors.title", value: "Turn Off Connectors?",
                              comment: "AI settings - Confirmation alert title when disabling external data connectors"),
            isPresented: $showDisableConnectorsAlert
        ) {
            Button(NSLocalizedString("settings.ai.disableConnectors.confirmButton", value: "Turn Off",
                                     comment: "AI settings - Destructive button to confirm turning off connectors"),
                   role: .destructive) {
                enableConnectors = false
            }
            Button(NSLocalizedString("settings.ai.disableConnectors.cancelButton", value: "Cancel",
                                     comment: "AI settings - Cancel button in disable-connectors confirmation alert"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.ai.disableConnectors.message", value: "All connected Connectors will be disconnected.",
                                   comment: "AI settings - Alert message explaining consequences of disabling connectors"))
        }
    }
}

// MARK: - Connectors List

private struct ConnectorsListView: View {
    let connectorViewModel: AISettingsConnectorViewModel
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("settings.ai.connectors.listSectionTitle", value: "External Data Connectors", comment: "AI settings - Sub-section title for connectors list within the container"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(connectorViewModel.connectors.enumerated()), id: \.element.id) { index, connector in
                    ConnectorRowView(connector: connector, enabled: enabled) {
                        connectorViewModel.toggleConnection(for: connector)
                    } refreshAction: {
                        connectorViewModel.refreshConnection(for: connector)
                    }
                    if index < connectorViewModel.connectors.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 8)
            .themedBackground(ThemedColor(light: .white.withAlphaComponent(0.3),
                                           dark: .white.withAlphaComponent(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .themedStroke(.border)
            }
        }
        .padding(.vertical, 12)
        .opacity(enabled ? 1.0 : 0.4)
    }
}

// MARK: - Connector Row

private struct ConnectorRowView: View {
    let connector: ConnectorItemState
    let enabled: Bool
    let action: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            connectorIcon
            connectorInfo
            Spacer(minLength: 8)
            connectorActions
        }
        .padding(.vertical, 8)
    }

    private var connectorIcon: some View {
        Group {
            if let icon = connector.template.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 20, height: 20)
            }
        }
        .frame(width: 31, height: 31)
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var connectorInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(connector.template.name)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)

                if connector.isAuthorizationPending || connector.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            HStack(spacing: 6) {
                if connector.status.isConnected {
                    ConnectorStatusBadge()
                    
                    Text(connector.lastSyncTime)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                } else {
                    Text(NSLocalizedString("settings.ai.connectors.notConnectedRowStatus", value: "Not connected", comment: "AI settings - Connector row status text when not connected"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                }
            }

            if let errorMessage = connector.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }
        }
    }

    private var connectorActions: some View {
        HStack(spacing: 8) {
            if connector.isAuthorizationPending || connector.isLoading {
                refreshButton
            }
            manageButton
        }
        .frame(minWidth: 144, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var manageButton: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connector.status.isConnected ? "xmark.circle" : "link")
                    .font(.system(size: 11))
                Text(connector.actionTitle)
                    .font(.system(size: 13))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 92)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!enabled || (connector.isLoading && !connector.isAuthorizationPending))
    }

    private var refreshButton: some View {
        Button {
            refreshAction()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(NSLocalizedString("settings.ai.connectors.refreshButtonTooltip", value: "Refresh connector status", comment: "AI settings - Tooltip for refreshing connector status"))
        .disabled(!enabled || (connector.isLoading && !connector.isAuthorizationPending))
    }
}

// MARK: - Connector Status Badge

private struct ConnectorStatusBadge: View {
    var body: some View {
        Text(NSLocalizedString("settings.ai.connectors.connectedStatus", value: "Connected", comment: "AI settings - Badge text when connector is successfully connected"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.004, green: 0.4, blue: 0.19))
            .padding(.horizontal, 4)
            .background(Color(red: 0.86, green: 0.99, blue: 0.91))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Reusable Components

private struct AISectionView<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AIContainerView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .themedStroke(.border)
        }
    }
}

private struct AIToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled: Bool = true

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { enabled ? isOn : false },
            set: { isOn = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .opacity(enabled ? 1.0 : 0.4)
            Spacer(minLength: 12)
            Toggle("", isOn: effectiveBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .disabled(!enabled)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AINavigationRow: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .themedForeground(.textSecondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(enabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Helpers

private func notifyNativeSettingsChanged() {
    let settings = PhiPreferences.AISettings.buildConfig()
    ChromiumLauncher.sharedInstance().bridge?.nativeSettingsChanged(settings)
    AppLogDebug("[AISettings] Native settings changed notification sent: \(settings)")
}

#Preview {
    AISettingView()
}
