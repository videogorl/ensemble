import EnsembleCore
import SwiftUI

public struct SettingsView: View {
    @State private var showingAddAccount = false
    @State private var showingDeleteAlert = false
    @State private var sourceToDelete: MusicSource?

    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let accountManager = DependencyContainer.shared.accountManager

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
            } footer: {
                if accountManager.enabledMusicSources().isEmpty {
                    Text("Add a Plex server to access your music library.")
                }
            }

            // Appearance section
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent Color")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
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
            }

            // Playback section
            Section("Playback") {
                NavigationLink {
                    AudioQualitySettingsView()
                } label: {
                    HStack {
                        Image(systemName: "waveform")
                            .frame(width: 44)
                        Text("Audio Quality")
                    }
                }
            }

            // Storage section
            Section("Storage") {
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "internaldrive")
                            .frame(width: 44)
                        Text("Manage Downloads")
                    }
                }
            }

            // About section
            Section("About") {
                HStack {
                    Image(systemName: "info.circle")
                        .frame(width: 44)
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundColor(.secondary)
                }

                Link(destination: URL(string: "https://github.com")!) {
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
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAddAccount) {
            AddPlexAccountView()
        }
        .alert("Remove Music Source", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                sourceToDelete = nil
            }
            Button("Remove", role: .destructive) {
                if let source = sourceToDelete {
                    accountManager.removeMusicSource(source.id)
                    sourceToDelete = nil
                }
            }
        } message: {
            if let source = sourceToDelete {
                Text("Remove \(source.displayName)? Your music will remain in the library until the next sync.")
            }
        }
    }
}

// MARK: - Music Source Row

struct MusicSourceRow: View {
    let source: MusicSource

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
            } footer: {
                Text("Higher quality downloads use more storage space.")
            }
        }
        .navigationTitle("Audio Quality")
        .navigationBarTitleDisplayMode(.inline)
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
        .navigationBarTitleDisplayMode(.inline)
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
