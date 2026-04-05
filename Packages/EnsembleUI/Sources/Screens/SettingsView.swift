import EnsembleCore
import SwiftUI

/// Legacy settings view — redirects to ProfileView.
/// Kept for backward compatibility and for sub-views defined in this file
/// (AudioQualitySettingsView, ConnectionPolicySettingsView, etc.)
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        ProfileView()
    }
}

// MARK: - Music Source Account Row

struct MusicSourceAccountRow: View {
    let sourceName: String
    let accountIdentifier: String

    var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
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
