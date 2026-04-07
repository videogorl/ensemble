import EnsembleCore
import SwiftUI

/// Sync settings page showing iCloud sync toggles for each feature.
/// Navigated to from ProfileView. Master toggle at top,
/// individual feature toggles below with dependency dimming.
public struct SyncSettingsView: View {
    @ObservedObject private var syncSettings: SyncSettingsManager
    private let dependencies = DependencyContainer.shared

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

            Section {
                Button {
                    Task {
                        await dependencies.runManualSync()
                    }
                } label: {
                    HStack(spacing: 12) {
                        if syncSettings.isManualSyncInProgress {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(syncSettings.isManualSyncInProgress ? "Syncing…" : "Sync Now")
                                .foregroundColor(.primary)
                            Text("Refresh iCloud settings, sources, libraries, and profile status")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(syncSettings.isManualSyncInProgress)

                if let lastManualSyncDate = syncSettings.lastManualSyncDate {
                    statusTimestampRow(
                        title: "Last Manual Sync",
                        timestamp: lastManualSyncDate
                    )
                }
            } header: {
                Text("Actions")
            }

            Section {
                statusRow(profileStatusPresentation)

                ForEach(SyncSettingsManager.SyncFeature.allCases) { feature in
                    statusRow(featureStatusPresentation(for: feature))
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Rows show the last push or pull this device observed. Use Sync Now if a new device looks partially synced.")
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

    private struct StatusPresentation: Identifiable {
        let id: String
        let title: String
        let symbolName: String
        let status: String
        let detail: String
        let tint: Color
        let timestamp: Date?
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

    @ViewBuilder
    private func statusRow(_ presentation: StatusPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(presentation.title, systemImage: presentation.symbolName)
                    .foregroundColor(.primary)

                Spacer()

                Text(presentation.status)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(presentation.tint)
            }

            Text(presentation.detail)
                .font(.caption)
                .foregroundColor(.secondary)

            if let timestamp = presentation.timestamp {
                Text("Updated \(formattedTimestamp(timestamp))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusTimestampRow(title: String, timestamp: Date) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formattedTimestamp(timestamp))
                .foregroundColor(.secondary)
        }
    }

    private var profileStatusPresentation: StatusPresentation {
        let status = syncSettings.profileStatus
        switch status.phase {
        case .unknown:
            return StatusPresentation(
                id: "profile",
                title: "Profile",
                symbolName: "person.crop.circle",
                status: "Not Checked",
                detail: status.detail,
                tint: .secondary,
                timestamp: status.date
            )

        case .noRecord:
            return StatusPresentation(
                id: "profile",
                title: "Profile",
                symbolName: "person.crop.circle",
                status: "No Cloud Record",
                detail: status.detail,
                tint: .secondary,
                timestamp: status.date
            )

        case .transport(let transportState):
            return StatusPresentation(
                id: "profile",
                title: "Profile",
                symbolName: "person.crop.circle",
                status: profileStatusText(for: transportState, direction: status.direction),
                detail: status.detail,
                tint: profileTint(for: transportState),
                timestamp: status.date
            )
        }
    }

    private func featureStatusPresentation(
        for feature: SyncSettingsManager.SyncFeature
    ) -> StatusPresentation {
        let state = syncSettings.featureState(for: feature)
        let activity = syncSettings.featureActivity(for: feature)

        if !syncSettings.isFeatureEnabled(feature) {
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Off",
                detail: "Sync is off for this feature on this device.",
                tint: .secondary,
                timestamp: activity?.date
            )
        }

        switch state {
        case .idle:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: activity.flatMap(statusText(for:)) ?? "Ready",
                detail: activity?.detail ?? "Waiting for a local or iCloud change.",
                tint: activity == nil ? .secondary : .green,
                timestamp: activity?.date
            )

        case .bootstrapping:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Checking iCloud",
                detail: "Refreshing the latest value from iCloud.",
                tint: .secondary,
                timestamp: activity?.date
            )

        case .appliedRemote:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: activity.flatMap(statusText(for:)) ?? "Pulled from iCloud",
                detail: activity?.detail ?? "Applied the latest value from iCloud.",
                tint: .green,
                timestamp: activity?.date
            )

        case .seededLocal:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: activity.flatMap(statusText(for:)) ?? "Pushed from This Device",
                detail: activity?.detail ?? "Uploaded the local value to iCloud.",
                tint: .green,
                timestamp: activity?.date
            )

        case .waitingForTransport:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Waiting for iCloud",
                detail: "The iCloud key-value store has not delivered this feature yet.",
                tint: .orange,
                timestamp: activity?.date
            )

        case .transportUnavailable:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "iCloud Unavailable",
                detail: "This device cannot reach iCloud key-value sync right now.",
                tint: .orange,
                timestamp: activity?.date
            )

        case .error:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Error",
                detail: activity?.detail ?? "Sync hit an error for this feature.",
                tint: .red,
                timestamp: activity?.date
            )
        }
    }

    private func statusText(for activity: SyncSettingsManager.SyncFeatureActivity) -> String {
        switch activity.direction {
        case .pulledFromICloud:
            return "Pulled from iCloud"
        case .pushedFromThisDevice:
            return "Pushed from This Device"
        case nil:
            return "Updated"
        }
    }

    private func profileStatusText(
        for state: CloudSyncService.ProfileTransportState,
        direction: SyncSettingsManager.SyncDirection?
    ) -> String {
        switch state {
        case .unknown:
            return "Not Checked"
        case .available:
            switch direction {
            case .pulledFromICloud:
                return "Pulled from iCloud"
            case .pushedFromThisDevice:
                return "Pushed from This Device"
            case nil:
                return "Available"
            }
        case .notAuthenticated:
            return "Sign In Required"
        case .networkUnavailable:
            return "Offline"
        case .quotaExceeded:
            return "Quota Exceeded"
        case .rateLimited:
            return "Rate Limited"
        case .error:
            return "Error"
        }
    }

    private func profileTint(for state: CloudSyncService.ProfileTransportState) -> Color {
        switch state {
        case .available:
            return .green
        case .unknown:
            return .secondary
        case .notAuthenticated, .networkUnavailable, .rateLimited:
            return .orange
        case .quotaExceeded, .error:
            return .red
        }
    }

    private func symbolName(for feature: SyncSettingsManager.SyncFeature) -> String {
        switch feature {
        case .sources:
            return "music.note.list"
        case .libraries:
            return "square.stack.3d.up"
        case .pins:
            return "pin"
        case .accentColor:
            return "paintpalette"
        case .swipeActions:
            return "hand.tap"
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
