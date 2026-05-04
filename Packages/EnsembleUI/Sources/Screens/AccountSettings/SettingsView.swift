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
        EnsembleUtilityRowLabel(
            iconSystemName: EnsembleDesign.Icon.playlist,
            title: sourceName,
            subtitle: accountIdentifier,
            iconFont: EnsembleDesign.Typography.utilityIcon
        )
    }
}

// MARK: - Audio Quality Settings

struct AudioQualitySettingsView: View {
    @AppStorage("streamingQuality") private var streamingQuality = "high"
    @AppStorage("downloadQuality") private var downloadQuality = "high"

    var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: "Audio Quality") {
            List {
                Section {
                    streamingQualityPicker
                } header: {
                    EnsembleUtilitySectionHeader("Streaming")
                } footer: {
                    Text("Lower quality uses less data when streaming over cellular.")
                }

                Section {
                    downloadQualityPicker
                } header: {
                    EnsembleUtilitySectionHeader("Downloads")
                } footer: {
                    Text("Higher quality downloads use more storage space.")
                }
            }
        } regularContent: {
            EnsembleUtilityCardSection(
                "Streaming",
                footer: "Lower quality uses less data when streaming over cellular."
            ) {
                EnsembleUtilityCardRow {
                    streamingQualityPicker
                }
            }

            EnsembleUtilityCardSection(
                "Downloads",
                footer: "Higher quality downloads use more storage space."
            ) {
                EnsembleUtilityCardRow {
                    downloadQualityPicker
                }
            }
        }
    }

    private var streamingQualityPicker: some View {
        Picker("Streaming Quality", selection: $streamingQuality) {
            Text("Original").tag("original")
            Text("High (320 kbps)").tag("high")
            Text("Medium (192 kbps)").tag("medium")
            Text("Low (128 kbps)").tag("low")
        }
    }

    private var downloadQualityPicker: some View {
        Picker("Download Quality", selection: $downloadQuality) {
            Text("Original").tag("original")
            Text("High (320 kbps)").tag("high")
            Text("Medium (192 kbps)").tag("medium")
            Text("Low (128 kbps)").tag("low")
        }
    }
}

// MARK: - Connection Policy Settings

struct ConnectionPolicySettingsView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator

    var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: "Connection Security") {
            List {
                Section {
                    policyPicker
                } footer: {
                    Text("Changing this setting rebuilds server connection candidates and refreshes provider routing.")
                }
            }
        } regularContent: {
            EnsembleUtilityCardSection(
                nil,
                footer: "Changing this setting rebuilds server connection candidates and refreshes provider routing."
            ) {
                EnsembleUtilityCardRow {
                    policyPicker
                }
            }
        }
    }

    private var policyPicker: some View {
        Picker("Allow Insecure Connections", selection: policyBinding) {
            ForEach(AllowInsecureConnectionsPolicy.allCases, id: \.rawValue) { policy in
                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.textSpacing) {
                    Text(policy.title)
                    Text(policy.subtitle)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
                .tag(policy)
            }
        }
        .pickerStyle(.inline)
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
        EnsembleAdaptiveUtilityScaffold(title: "Storage") {
            List {
                Section {
                    downloadedMusicRow
                }

                Section {
                    clearDownloadsButton
                } footer: {
                    Text("This will remove all downloaded music from your device. You can re-download music anytime.")
                }
            }
        } regularContent: {
            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    downloadedMusicRow
                }
            }

            EnsembleUtilityCardSection(
                nil,
                footer: "This will remove all downloaded music from your device. You can re-download music anytime."
            ) {
                EnsembleUtilityCardRow {
                    clearDownloadsButton
                }
            }
        }
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

    private var downloadedMusicRow: some View {
        HStack {
            Text("Downloaded Music")
            Spacer()
            Text(totalSize)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
    }

    private var clearDownloadsButton: some View {
        Button(role: .destructive) {
            showingClearAlert = true
        } label: {
            Text("Clear All Downloads")
        }
    }

    private func calculateStorage() {
        Task {
            let manager = DependencyContainer.shared.downloadManager
            let size = try? await manager.getTotalDownloadSize()
            totalSize = MediaFormatters.bytes(size ?? 0)
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
