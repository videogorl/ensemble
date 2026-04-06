import EnsembleCore
import SwiftUI

/// Sync settings page showing iCloud sync toggles for each feature.
/// Navigated to from ProfileView. Master toggle at top,
/// individual feature toggles below with dependency dimming.
public struct SyncSettingsView: View {
    @ObservedObject private var syncSettings: SyncSettingsManager

    public init(syncSettings: SyncSettingsManager = DependencyContainer.shared.syncSettingsManager) {
        self.syncSettings = syncSettings
    }

    public var body: some View {
        List {
            Section {
                // Master sync toggle
                Toggle(isOn: $syncSettings.isMasterSyncEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync This Device")
                            Text("Sync app data across your devices via iCloud")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "icloud")
                    }
                }
            }

            // Individual feature toggles
            if syncSettings.isMasterSyncEnabled {
                Section {
                    ForEach(SyncSettingsManager.SyncFeature.allCases) { feature in
                        featureToggle(for: feature)
                    }
                } header: {
                    Text("Features")
                } footer: {
                    Text("Sync settings are per-device. Turning off a toggle on this device won't affect other devices.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("iCloud Sync")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func featureToggle(for feature: SyncSettingsManager.SyncFeature) -> some View {
        let isToggleable = syncSettings.isFeatureToggleable(feature)

        Toggle(isOn: Binding(
            get: { syncSettings.rawToggleValue(feature) },
            set: { syncSettings.setFeatureEnabled(feature, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayName)
                Text(feature.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(!isToggleable)
    }
}
