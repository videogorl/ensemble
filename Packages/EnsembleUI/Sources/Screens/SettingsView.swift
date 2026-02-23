import EnsembleCore
import SwiftUI

public struct SettingsView: View {
    @State private var showingAddAccount = false
    @State private var showingDeleteAlert = false
    @State private var showingClearDataAlert = false
    @State private var sourceToDelete: MusicSource?

    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let playbackService = DependencyContainer.shared.playbackService
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    private let cacheManager = DependencyContainer.shared.cacheManager

    @State private var isAutoplayEnabled = DependencyContainer.shared.playbackService.isAutoplayEnabled

    // Hardcoded support URL — safe to force-unwrap as a named constant (literal cannot fail)
    private static let supportURL = URL(string: "https://github.com/")!

    public init() {}

    public var body: some View {
        List {
            // Music Sources section
            Section {
                ForEach(accountManager.enabledMusicSources()) { source in
                    MusicSourceRow(source: source)
                }
                .onDelete { indexSet in
                    guard let index = indexSet.first else { return }
                    let sources = accountManager.enabledMusicSources()
                    sourceToDelete = sources[index]
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
                if accountManager.enabledMusicSources().isEmpty {
                    Text("Add a Plex server to access your music library.")
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
            } header: {
                Text("Accent Color: \(settingsManager.accentColor.rawValue.capitalized)")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            }

            // Playback section
            Section(header: Text("Playback").textCase(nil)) {
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
            Section(header: Text("Storage").textCase(nil)) {
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "internaldrive")
                            .frame(width: 44)
                        Text("Manage Downloads")
                    }
                }
                
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
            Section(header: Text("Reset").textCase(nil)) {
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

            // About section
            Section(header: Text("About").textCase(nil)) {
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
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAddAccount) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .alert("Remove Music Source", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                sourceToDelete = nil
            }
            Button("Remove", role: .destructive) {
                if let source = sourceToDelete {
                    accountManager.removeMusicSource(source.id)
                    
                    // Clean up CoreData for this source
                    Task {
                        await syncCoordinator.cleanupRemovedSource(source.id)
                        syncCoordinator.refreshProviders()
                    }
                    
                    sourceToDelete = nil
                }
            }
        } message: {
            if let source = sourceToDelete {
                Text("Remove \(source.displayName)? Your music will remain in the library until the next sync.")
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
}

// MARK: - Music Source Row

struct MusicSourceRow: View {
    let source: MusicSource
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName)
                    .font(.body)

                Text(source.accountName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Show connection count for debugging
                if let account = accountManager.plexAccounts.first(where: { $0.id == source.id.accountId }),
                   let server = account.servers.first(where: { $0.id == source.id.serverId }) {
                    Text("\(server.connections.count) connection\(server.connections.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Audio Quality Settings

struct AudioQualitySettingsView: View {
    @AppStorage("streamingQuality") private var streamingQuality = "original"
    @AppStorage("downloadQuality") private var downloadQuality = "original"

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
