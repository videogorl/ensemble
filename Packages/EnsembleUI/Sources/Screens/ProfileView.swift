import EnsembleCore
import SwiftUI

/// Main profile view that replaces SettingsView.
/// Shows profile header (image + name) followed by all settings sections.
/// Modeled after Apple's iCloud Settings panel aesthetic.
public struct ProfileView: View {
    @ObservedObject private var profileStore = DependencyContainer.shared.userProfileStore
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    private let playbackService = DependencyContainer.shared.playbackService
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    private let cacheManager = DependencyContainer.shared.cacheManager

    @State private var showingDeleteAlert = false
    @State private var showingClearDataAlert = false
    @State private var accountToDelete: PlexAccountConfig?
    @State private var isAutoplayEnabled = DependencyContainer.shared.playbackService.isAutoplayEnabled

    #if DEBUG
    @AppStorage("debugSimulateOffline") private var debugSimulateOffline = false
    #endif

    private static let supportURL = URL(string: "https://ensemble.videogorl.me")!

    public init() {}

    public var body: some View {
        List {
            // Profile header — image + name
            Section {
                ProfileHeaderView(profileStore: profileStore)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            // Music Sources
            sourcesSection

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
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .miniPlayerBottomSpacing()
        .navigationTitle("Profile")
        #if os(iOS)
        // Force inline title to prevent scroll pocket tracking in the sheet's nav bar.
        // Without this, iOS 26's scroll pocket system in the sheet conflicts with the
        // parent tab view's scroll pocket system, causing a feedback loop (279+ invalidations).
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

            Button {
                navigationCoordinator.showingAddAccount = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(settingsManager.accentColor.color)
                        .frame(width: 44)
                    Text("Add Plex Account")
                }
            }
        } header: {
            Text("Music Sources")
                .foregroundColor(.accentColor)
                .textCase(nil)
        } footer: {
            if accountManager.plexAccounts.isEmpty {
                Text("Add a music source account to access your libraries.")
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    ForEach(AppAccentColor.allCases) { colorOption in
                        Circle()
                            .fill(colorOption.color)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary, lineWidth: settingsManager.accentColor == colorOption ? 2 : 0)
                                    .frame(width: 36, height: 36)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                settingsManager.setAccentColor(colorOption)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.vertical, 4)

            Toggle(isOn: $settingsManager.auroraVisualizationEnabled) {
                HStack {
                    Image(systemName: "sparkles")
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aurora Visualization")
                        Text("Animated background that reacts to music")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Accent Color: \(settingsManager.accentColor.rawValue.capitalized)")
                .foregroundColor(.accentColor)
                .textCase(nil)
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section(header: Text("Playback").foregroundColor(.accentColor).textCase(nil)) {
            Toggle(isOn: $isAutoplayEnabled) {
                HStack {
                    Image(systemName: "infinity.circle.fill")
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autoplay")
                        Text("Continue with similar tracks when queue ends")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: isAutoplayEnabled) { _ in
                playbackService.toggleAutoplay()
            }

            Toggle(isOn: $settingsManager.scrobblingEnabled) {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scrobbling")
                        Text("Report play counts to your Plex server")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            NavigationLink {
                AudioQualitySettingsView()
            } label: {
                HStack {
                    Image(systemName: "waveform")
                        .frame(width: 44)
                    Text("Audio Quality")
                }
            }

            NavigationLink {
                ConnectionPolicySettingsView()
            } label: {
                HStack {
                    Image(systemName: "lock.shield")
                        .frame(width: 44)
                    Text("Connection Security")
                }
            }

            NavigationLink {
                TrackSwipeActionsSettingsView()
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 44)
                    Text("Track Swipe Actions")
                }
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section(header: Text("Storage").foregroundColor(.accentColor).textCase(nil)) {
            Button(role: .destructive) {
                showingClearDataAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .frame(width: 44)
                    Text("Clear All Library Data")
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section(header: Text("Reset").foregroundColor(.accentColor).textCase(nil)) {
            Button(role: .destructive) {
                for account in accountManager.plexAccounts {
                    accountManager.removePlexAccount(id: account.id)
                }
            } label: {
                HStack {
                    Image(systemName: "person.2.slash")
                        .frame(width: 44)
                    Text("Remove All Accounts")
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section(header: Text("Developer").foregroundColor(.accentColor).textCase(nil)) {
            NavigationLink {
                LogsSettingsView()
            } label: {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .frame(width: 44)
                    Text("Logs")
                }
            }

            #if DEBUG
            Toggle(isOn: $debugSimulateOffline) {
                HStack {
                    Image(systemName: "wifi.slash")
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulate No Connection")
                        Text("Forces app into offline mode for testing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: debugSimulateOffline) { simulating in
                DependencyContainer.shared.networkMonitor.simulateOffline(simulating)
            }

            Button {
                DependencyContainer.shared.toastCenter.show(
                    ToastPayload(
                        style: .info,
                        iconSystemName: "bell.fill",
                        title: "Test Toast",
                        message: "This is a test notification"
                    )
                )
            } label: {
                HStack {
                    Image(systemName: "bell.badge")
                        .frame(width: 44)
                    Text("Send Test Toast")
                }
            }
            #endif
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section(header: Text("About").foregroundColor(.accentColor).textCase(nil)) {
            HStack {
                Image(systemName: "info.circle")
                    .frame(width: 44)
                Text("Version")
                Spacer()
                Text(Bundle.main.appVersion)
                    .foregroundColor(.secondary)
            }

            Link(destination: Self.supportURL) {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .frame(width: 44)
                    Text("Help & Support")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

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
