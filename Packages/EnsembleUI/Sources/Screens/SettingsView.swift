import EnsembleCore
import SwiftUI

public struct SettingsView: View {
    @State private var showingAddAccount = false
    @State private var showingDeleteAlert = false
    @State private var showingClearDataAlert = false
    @State private var accountToDelete: PlexAccountConfig?

    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    private let playbackService = DependencyContainer.shared.playbackService
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    private let cacheManager = DependencyContainer.shared.cacheManager

    @State private var isAutoplayEnabled = DependencyContainer.shared.playbackService.isAutoplayEnabled
    #if DEBUG
    @AppStorage("debugSimulateOffline") private var debugSimulateOffline = false
    #endif

    // Hardcoded support URL — safe to force-unwrap as a named constant (literal cannot fail)
    private static let supportURL = URL(string: "https://ensemble.videogorl.me")!

    public init() {}

    public var body: some View {
        List {
            // Music Sources section
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
                    showingAddAccount = true
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

            // Appearance section
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

            // Playback section
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

            // Storage section
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
            
            // Debug section
            Section(header: Text("Reset").foregroundColor(.accentColor).textCase(nil)) {
                Button(role: .destructive) {
                    // Clear all accounts from keychain
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

            #if DEBUG
            // Developer tools section (DEBUG builds only)
            Section(header: Text("Developer").foregroundColor(.accentColor).textCase(nil)) {
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

                // Test toast button
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
            }
            #endif

            // About section
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
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .miniPlayerBottomSpacing(140)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAddAccount) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .alert("Remove Account", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
            Button("Remove", role: .destructive) {
                if let account = accountToDelete {
                    let sourceIds = enabledSources(for: account)
                    let serverIds = account.servers.map(\.id)
                    accountManager.removePlexAccount(id: account.id)

                    // Clean up CoreData for all libraries tied to this account.
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

// MARK: - Music Source Account Row

struct MusicSourceAccountRow: View {
    let sourceName: String
    let accountIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(sourceName)
                    .font(.body)

                Text(accountIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Audio Quality Settings

struct AudioQualitySettingsView: View {
    @AppStorage("streamingQuality") private var streamingQuality = "high"
    @AppStorage("downloadQuality") private var downloadQuality = "high"

    var body: some View {
        List {
            Section {
                Picker("Streaming Quality", selection: $streamingQuality) {
                    Text("Original").tag("original")
                    Text("High (320 kbps)").tag("high")
                    Text("Medium (192 kbps)").tag("medium")
                    Text("Low (128 kbps)").tag("low")
                }
            } header: {
                Text("Streaming")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("Lower quality uses less data when streaming over cellular.")
            }

            Section {
                Picker("Download Quality", selection: $downloadQuality) {
                    Text("Original").tag("original")
                    Text("High (320 kbps)").tag("high")
                    Text("Medium (192 kbps)").tag("medium")
                    Text("Low (128 kbps)").tag("low")
                }
            } header: {
                Text("Downloads")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("Higher quality downloads use more storage space.")
            }
        }
        .navigationTitle("Audio Quality")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Connection Policy Settings

struct ConnectionPolicySettingsView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator

    var body: some View {
        List {
            Section {
                Picker("Allow Insecure Connections", selection: policyBinding) {
                    ForEach(AllowInsecureConnectionsPolicy.allCases, id: \.rawValue) { policy in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.title)
                            Text(policy.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(policy)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("Changing this setting rebuilds server connection candidates and refreshes provider routing.")
            }
        }
        .navigationTitle("Connection Security")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var policyBinding: Binding<AllowInsecureConnectionsPolicy> {
        Binding(
            get: { settingsManager.allowInsecureConnectionsPolicy },
            set: { newPolicy in
                settingsManager.setAllowInsecureConnectionsPolicy(newPolicy)
                accountManager.clearAPIClientCache()
                syncCoordinator.refreshProviders()
            }
        )
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    @State private var totalSize: String = "Calculating..."
    @State private var showingClearAlert = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Downloaded Music")
                    Spacer()
                    Text(totalSize)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showingClearAlert = true
                } label: {
                    Text("Clear All Downloads")
                }
            } footer: {
                Text("This will remove all downloaded music from your device. You can re-download music anytime.")
            }
        }
        .navigationTitle("Storage")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Clear Downloads", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                // Clear downloads
            }
        } message: {
            Text("This will remove all downloaded music. This action cannot be undone.")
        }
        .onAppear {
            calculateStorage()
        }
    }

    private func calculateStorage() {
        Task {
            let manager = DependencyContainer.shared.downloadManager
            let size = try? await manager.getTotalDownloadSize()
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            totalSize = formatter.string(fromByteCount: size ?? 0)
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
