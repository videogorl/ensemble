import EnsembleCore
import SwiftUI

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
    @AppStorage(PlaybackSettingsPreference.streamingQualityKey)
    private var streamingQuality = PlaybackSettingsPreference.defaultStreamingQuality
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

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
