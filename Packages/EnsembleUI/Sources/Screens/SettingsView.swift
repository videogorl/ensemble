import EnsembleCore
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var authViewModel: AuthViewModel
    @State private var showingSignOutAlert = false

    public init(authViewModel: AuthViewModel) {
        self.authViewModel = authViewModel
    }

    public var body: some View {
        List {
            // Account section
            Section("Account") {
                if let server = authViewModel.selectedServer {
                    HStack {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .font(.body)

                            Text(server.platform ?? "Plex Server")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let library = authViewModel.selectedLibrary {
                    Button {
                        Task {
                            await authViewModel.changeLibrary()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "music.note.house")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                                .frame(width: 44)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(library.title)
                                    .font(.body)

                                Text("Tap to change library")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Button(role: .destructive) {
                    showingSignOutAlert = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .frame(width: 44)
                        Text("Sign Out")
                    }
                }
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
        .alert("Sign Out", isPresented: $showingSignOutAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    await authViewModel.signOut()
                }
            }
        } message: {
            Text("Are you sure you want to sign out? Your downloaded music will be preserved.")
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
