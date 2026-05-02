import EnsembleCore
import SwiftUI

/// Main profile view that replaces SettingsView.
/// Shows profile header (image + name) followed by all settings sections.
/// Modeled after Apple's iCloud Settings panel aesthetic.
public struct ProfileView: View {
    @ObservedObject private var profileStore = DependencyContainer.shared.userProfileStore
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    private let playbackService = DependencyContainer.shared.playbackService
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    private let cacheManager = DependencyContainer.shared.cacheManager

    @State private var showingDeleteAlert = false
    @State private var showingClearDataAlert = false
    @State private var showingNameEditor = false
    @State private var accountToDelete: PlexAccountConfig?
    @State private var isAutoplayEnabled = DependencyContainer.shared.playbackService.isAutoplayEnabled

    #if DEBUG
    @AppStorage("debugSimulateOffline") private var debugSimulateOffline = false
    #endif

    private static let supportURL = URL(string: "https://ensemble.videogorl.me")!

    public init() {}

    public var body: some View {
        profileContent
            .miniPlayerBottomSpacing()
            #if os(iOS)
            .ignoresSafeArea(.keyboard)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showingNameEditor) {
                TextInputView(
                    title: "Edit Name",
                    placeholder: "Your Name",
                    initialText: profileStore.profile.displayName ?? "",
                    actionTitle: "Save"
                ) { newName in
                    profileStore.updateName(newName)
                }
            }
            .navigationTitle("Profile")
            .alert("Remove Account", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    accountToDelete = nil
                }
                Button("Remove", role: .destructive) {
                    if let account = accountToDelete {
                        let sourceIds = enabledSources(for: account)
                        let serverIds = account.servers.map(\.id)
                        accountManager.removePlexAccount(id: account.id)

                        Task {
                            for sourceId in sourceIds {
                                await syncCoordinator.cleanupRemovedSource(sourceId)
                            }
                            for serverId in serverIds {
                                await syncCoordinator.cleanupServerPlaylists(accountId: account.id, serverId: serverId)
                            }
                            syncCoordinator.refreshProviders()
                        }

                        accountToDelete = nil
                    }
                }
            } message: {
                if let account = accountToDelete {
                    Text("Remove Plex account \(account.accountIdentifier)? Libraries from this account will be removed from local cache.")
                }
            }
            .alert("Clear All Library Data", isPresented: $showingClearDataAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All Data", role: .destructive) {
                    Task {
                        try? await cacheManager.clearAllCaches()
                    }
                }
            } message: {
                Text("This will delete all synced music data (tracks, albums, artists, playlists). Your account settings will be preserved. You'll need to re-sync after clearing.")
            }
    }

    @ViewBuilder
    private var profileContent: some View {
        #if os(macOS)
        macOSProfileContent
        #else
        List {
            // Profile header — image + name
            Section {
                ProfileHeaderView(
                    profileStore: profileStore,
                    onEditName: { showingNameEditor = true }
                )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            // Music Sources
            sourcesSection

            // iCloud Sync
            Section {
                NavigationLink {
                    SyncSettingsView()
                } label: {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.cloud,
                        title: "iCloud Sync",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                }
            }

            // Appearance
            appearanceSection

            // Playback
            playbackSection

            // Storage
            storageSection

            // Reset
            resetSection

            // Developer
            developerSection

            // About
            aboutSection
        }
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Music Sources

    private var sourcesSection: some View {
        Section {
            ForEach(accountManager.plexAccounts) { account in
                NavigationLink {
                    MusicSourceAccountDetailView(accountId: account.id)
                } label: {
                    MusicSourceAccountRow(
                        sourceName: "Plex",
                        accountIdentifier: preferredAccountSubtitle(for: account)
                    )
                }
            }
            .onDelete { indexSet in
                guard let index = indexSet.first else { return }
                let accounts = accountManager.plexAccounts
                guard accounts.indices.contains(index) else { return }
                accountToDelete = accounts[index]
                showingDeleteAlert = true
            }

            // Navigate within the profile sheet rather than opening a second sheet.
            // iOS doesn't allow stacking sheets — the add-account sheet won't appear
            // while the profile sheet is already presented.
            NavigationLink {
                AddPlexAccountView(embedded: true)
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.addCircle,
                    title: "Add Plex Account",
                    iconColor: settingsManager.accentColor.color
                )
            }
        } header: {
            EnsembleUtilitySectionHeader("Music Sources")
        } footer: {
            if accountManager.plexAccounts.isEmpty {
                Text("Add a music source account to access your libraries.")
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
                HStack(spacing: EnsembleDesign.Spacing.lg) {
                    ForEach(AppAccentColor.allCases) { colorOption in
                        Circle()
                            .fill(colorOption.color)
                            .frame(
                                width: EnsembleScaffold.ProfileHeader.accentSwatchDimension,
                                height: EnsembleScaffold.ProfileHeader.accentSwatchDimension
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        EnsembleDesign.Color.primaryText,
                                        lineWidth: settingsManager.accentColor == colorOption
                                            ? EnsembleScaffold.ProfileHeader.accentSwatchSelectionLineWidth
                                            : 0
                                    )
                                    .frame(
                                        width: EnsembleScaffold.ProfileHeader.accentSwatchSelectionDimension,
                                        height: EnsembleScaffold.ProfileHeader.accentSwatchSelectionDimension
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                settingsManager.setAccentColor(colorOption)
                            }
                    }
                }
                .padding(.vertical, EnsembleScaffold.UtilityRow.subtleVerticalPadding)
            }
            .padding(.vertical, EnsembleScaffold.UtilityRow.subtleVerticalPadding)

            Toggle(isOn: $settingsManager.auroraVisualizationEnabled) {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.aurora,
                    title: "Aurora Visualization",
                    subtitle: "Animated background that reacts to music",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
        } header: {
            EnsembleUtilitySectionHeader("Accent Color: \(settingsManager.accentColor.rawValue.capitalized)")
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section(header: EnsembleUtilitySectionHeader("Playback")) {
            Toggle(isOn: $isAutoplayEnabled) {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.autoplay,
                    title: "Autoplay",
                    subtitle: "Continue with similar tracks when queue ends",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
            .onChange(of: isAutoplayEnabled) { _ in
                playbackService.toggleAutoplay()
            }

            Toggle(isOn: $settingsManager.scrobblingEnabled) {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.scrobble,
                    title: "Scrobbling",
                    subtitle: "Report play counts to your Plex server",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            NavigationLink {
                AudioQualitySettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.waveform,
                    title: "Audio Quality",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            NavigationLink {
                ConnectionPolicySettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.secureConnection,
                    title: "Connection Security",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            NavigationLink {
                TrackSwipeActionsSettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.editPlaylist,
                    title: "Track Swipe Actions",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section(header: EnsembleUtilitySectionHeader("Storage")) {
            Button(role: .destructive) {
                showingClearDataAlert = true
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.delete,
                    title: "Clear All Library Data",
                    iconColor: EnsembleDesign.Color.destructive
                )
                .foregroundColor(EnsembleDesign.Color.destructive)
            }
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section(header: EnsembleUtilitySectionHeader("Reset")) {
            Button(role: .destructive) {
                for account in accountManager.plexAccounts {
                    accountManager.removePlexAccount(id: account.id)
                }
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.removeAccounts,
                    title: "Remove All Accounts",
                    iconColor: EnsembleDesign.Color.destructive
                )
                .foregroundColor(EnsembleDesign.Color.destructive)
            }
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section(header: EnsembleUtilitySectionHeader("Developer")) {
            NavigationLink {
                LogsSettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.logs,
                    title: "Logs",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            #if DEBUG
            Toggle(isOn: $debugSimulateOffline) {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.offline,
                    title: "Simulate No Connection",
                    subtitle: "Forces app into offline mode for testing",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
            .onChange(of: debugSimulateOffline) { simulating in
                DependencyContainer.shared.networkMonitor.simulateOffline(simulating)
            }

            Button {
                DependencyContainer.shared.toastCenter.show(
                    ToastPayload(
                        style: .info,
                        iconSystemName: EnsembleDesign.Icon.notification,
                        title: "Test Toast",
                        message: "This is a test notification"
                    )
                )
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.notificationBadge,
                    title: "Send Test Toast",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
            #endif
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section(header: EnsembleUtilitySectionHeader("About")) {
            HStack {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.info,
                    title: "Version",
                    iconColor: EnsembleDesign.Color.primaryText
                )
                Spacer()
                Text(Bundle.main.appVersion)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }

            Link(destination: Self.supportURL) {
                HStack {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.help,
                        title: "Help & Support",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                    Spacer()
                    Image(systemName: EnsembleDesign.Icon.externalLinkSquare)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }
    }

    #if os(macOS)
    private var macOSProfileContent: some View {
        EnsembleUtilityScreenScaffold {
            EnsembleUtilityCardSection {
                ProfileHeaderView(
                    profileStore: profileStore,
                    onEditName: { showingNameEditor = true }
                )
            }

            macOSSourcesSection

            EnsembleUtilityCardSection {
                macNavigationRow {
                    SyncSettingsView()
                } label: {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.cloud,
                        title: "iCloud Sync",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                }
            }

            macOSAppearanceSection
            macOSPlaybackSection
            macOSStorageSection
            macOSResetSection
            macOSDeveloperSection
            macOSAboutSection
        }
    }

    private var macOSSourcesSection: some View {
        EnsembleUtilityCardSection(
            "Music Sources",
            footer: accountManager.plexAccounts.isEmpty ? "Add a music source account to access your libraries." : nil
        ) {
            ForEach(accountManager.plexAccounts) { account in
                EnsembleUtilityCardRow {
                    HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                        NavigationLink {
                            MusicSourceAccountDetailView(accountId: account.id)
                        } label: {
                            HStack {
                                MusicSourceAccountRow(
                                    sourceName: "Plex",
                                    accountIdentifier: preferredAccountSubtitle(for: account)
                                )
                                Spacer()
                                macChevron
                            }
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            accountToDelete = account
                            showingDeleteAlert = true
                        } label: {
                            Image(systemName: EnsembleDesign.Icon.delete)
                                .foregroundColor(EnsembleDesign.Color.destructive)
                        }
                        .buttonStyle(.plain)
                        .help("Remove account")
                    }
                }
            }

            if !accountManager.plexAccounts.isEmpty {
                EnsembleUtilityCardDivider()
            }

            macNavigationRow {
                AddPlexAccountView(embedded: true)
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.addCircle,
                    title: "Add Plex Account",
                    iconColor: settingsManager.accentColor.color
                )
            }
        }
    }

    private var macOSAppearanceSection: some View {
        EnsembleUtilityCardSection("Accent Color: \(settingsManager.accentColor.rawValue.capitalized)") {
            EnsembleUtilityCardRow {
                HStack(spacing: EnsembleDesign.Spacing.lg) {
                    ForEach(AppAccentColor.allCases) { colorOption in
                        Circle()
                            .fill(colorOption.color)
                            .frame(
                                width: EnsembleScaffold.ProfileHeader.accentSwatchDimension,
                                height: EnsembleScaffold.ProfileHeader.accentSwatchDimension
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        EnsembleDesign.Color.primaryText,
                                        lineWidth: settingsManager.accentColor == colorOption
                                            ? EnsembleScaffold.ProfileHeader.accentSwatchSelectionLineWidth
                                            : 0
                                    )
                                    .frame(
                                        width: EnsembleScaffold.ProfileHeader.accentSwatchSelectionDimension,
                                        height: EnsembleScaffold.ProfileHeader.accentSwatchSelectionDimension
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                settingsManager.setAccentColor(colorOption)
                            }
                    }
                }
            }

            EnsembleUtilityCardDivider()

            EnsembleUtilityCardRow {
                Toggle(isOn: $settingsManager.auroraVisualizationEnabled) {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.aurora,
                        title: "Aurora Visualization",
                        subtitle: "Animated background that reacts to music",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                }
            }
        }
    }

    private var macOSPlaybackSection: some View {
        EnsembleUtilityCardSection("Playback") {
            EnsembleUtilityCardRow {
                Toggle(isOn: $isAutoplayEnabled) {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.autoplay,
                        title: "Autoplay",
                        subtitle: "Continue with similar tracks when queue ends",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                }
                .onChange(of: isAutoplayEnabled) { _ in
                    playbackService.toggleAutoplay()
                }
            }

            EnsembleUtilityCardDivider()

            EnsembleUtilityCardRow {
                Toggle(isOn: $settingsManager.scrobblingEnabled) {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.scrobble,
                        title: "Scrobbling",
                        subtitle: "Report play counts to your Plex server",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                }
            }

            EnsembleUtilityCardDivider()

            macNavigationRow {
                AudioQualitySettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.waveform,
                    title: "Audio Quality",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            EnsembleUtilityCardDivider()

            macNavigationRow {
                ConnectionPolicySettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.secureConnection,
                    title: "Connection Security",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            EnsembleUtilityCardDivider()

            macNavigationRow {
                TrackSwipeActionsSettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.editPlaylist,
                    title: "Track Swipe Actions",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
        }
    }

    private var macOSStorageSection: some View {
        EnsembleUtilityCardSection("Storage") {
            macDestructiveButtonRow {
                showingClearDataAlert = true
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.delete,
                    title: "Clear All Library Data",
                    iconColor: EnsembleDesign.Color.destructive
                )
            }
        }
    }

    private var macOSResetSection: some View {
        EnsembleUtilityCardSection("Reset") {
            macDestructiveButtonRow {
                for account in accountManager.plexAccounts {
                    accountManager.removePlexAccount(id: account.id)
                }
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.removeAccounts,
                    title: "Remove All Accounts",
                    iconColor: EnsembleDesign.Color.destructive
                )
            }
        }
    }

    private var macOSDeveloperSection: some View {
        EnsembleUtilityCardSection("Developer") {
            macNavigationRow {
                LogsSettingsView()
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.logs,
                    title: "Logs",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }

            #if DEBUG
            EnsembleUtilityCardDivider()

            EnsembleUtilityCardRow {
                Toggle(isOn: $debugSimulateOffline) {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.offline,
                        title: "Simulate No Connection",
                        subtitle: "Forces app into offline mode for testing",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                }
                .onChange(of: debugSimulateOffline) { simulating in
                    DependencyContainer.shared.networkMonitor.simulateOffline(simulating)
                }
            }

            EnsembleUtilityCardDivider()

            macButtonRow {
                DependencyContainer.shared.toastCenter.show(
                    ToastPayload(
                        style: .info,
                        iconSystemName: EnsembleDesign.Icon.notification,
                        title: "Test Toast",
                        message: "This is a test notification"
                    )
                )
            } label: {
                EnsembleUtilityRowLabel(
                    iconSystemName: EnsembleDesign.Icon.notificationBadge,
                    title: "Send Test Toast",
                    iconColor: EnsembleDesign.Color.primaryText
                )
            }
            #endif
        }
    }

    private var macOSAboutSection: some View {
        EnsembleUtilityCardSection("About") {
            EnsembleUtilityCardRow {
                HStack {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.info,
                        title: "Version",
                        iconColor: EnsembleDesign.Color.primaryText
                    )
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }

            EnsembleUtilityCardDivider()

            Link(destination: Self.supportURL) {
                EnsembleUtilityCardRow {
                    HStack {
                        EnsembleUtilityRowLabel(
                            iconSystemName: EnsembleDesign.Icon.help,
                            title: "Help & Support",
                            iconColor: EnsembleDesign.Color.primaryText
                        )
                        Spacer()
                        Image(systemName: EnsembleDesign.Icon.externalLinkSquare)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func macNavigationRow<Destination: View, LabelContent: View>(
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            EnsembleUtilityCardRow {
                HStack {
                    label()
                    Spacer()
                    macChevron
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func macButtonRow<LabelContent: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        Button(action: action) {
            EnsembleUtilityCardRow {
                label()
            }
        }
        .buttonStyle(.plain)
    }

    private func macDestructiveButtonRow<LabelContent: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        Button(role: .destructive, action: action) {
            EnsembleUtilityCardRow {
                label()
                    .foregroundColor(EnsembleDesign.Color.destructive)
            }
        }
        .buttonStyle(.plain)
    }

    private var macChevron: some View {
        Image(systemName: EnsembleDesign.Icon.chevronRight)
            .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
            .foregroundColor(EnsembleDesign.Color.secondaryText.opacity(EnsembleScaffold.UtilityRow.chevronSubtleOpacity))
            .frame(width: EnsembleScaffold.UtilityRow.chevronLaneWidth, alignment: .trailing)
    }
    #endif

    // MARK: - Helpers

    private func enabledSources(for account: PlexAccountConfig) -> [MusicSourceIdentifier] {
        account.servers.flatMap { server in
            server.libraries.compactMap { library in
                guard library.isEnabled else { return nil }
                return MusicSourceIdentifier(
                    type: .plex,
                    accountId: account.id,
                    serverId: server.id,
                    libraryId: library.key
                )
            }
        }
    }

    private func preferredAccountSubtitle(for account: PlexAccountConfig) -> String {
        let trimmedEmail = account.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }

        let trimmedUsername = account.plexUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedUsername, !trimmedUsername.isEmpty {
            return trimmedUsername
        }

        return "Plex Account"
    }
}
