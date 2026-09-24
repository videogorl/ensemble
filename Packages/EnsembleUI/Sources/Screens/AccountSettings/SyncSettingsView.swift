import EnsembleDesignTokens
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
                masterToggleRow
            }

            Section {
                Button {
                    Task {
                        await dependencies.runManualSync()
                    }
                } label: {
                    HStack(spacing: EnsembleDesign.Spacing.md) {
                        if syncSettings.isManualSyncInProgress {
                            ProgressView()
                        } else {
                            Image(systemName: EnsembleDesign.Icon.refreshCycle)
                                .foregroundColor(EnsembleDesign.Color.accent)
                        }

                        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                            Text(syncSettings.isManualSyncInProgress ? "Syncing…" : "Sync Now")
                                .foregroundColor(EnsembleDesign.Color.primaryText)
                            Text("Refresh iCloud settings, sources, libraries, and profile status")
                                .font(EnsembleDesign.Typography.rowSecondary)
                                .foregroundColor(EnsembleDesign.Color.secondaryText)
                        }
                    }
                }
                .disabled(syncSettings.isManualSyncInProgress)
            } header: {
                EnsembleUtilitySectionHeader("Actions")
            }

            Section {
                profileStatusRow
            } header: {
                EnsembleUtilitySectionHeader("Profile")
            }

            if syncSettings.isMasterSyncEnabled {
                Section {
                    ForEach(SyncSettingsManager.SyncFeature.allCases) { feature in
                        featureRow(for: feature)
                    }
                } header: {
                    EnsembleUtilitySectionHeader("Features")
                } footer: {
                    Text("Rows show the last push or pull this device observed. Turning off a toggle only affects this device.")
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

    private var masterToggleRow: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs + EnsembleDesign.Spacing.xxs) {
            Toggle(isOn: $syncSettings.isMasterSyncEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                        Text("Sync This Device")
                        Text("Sync app data across your devices via iCloud.")
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                } icon: {
                    Image(systemName: EnsembleDesign.Icon.cloud)
                }
            }

            if let lastManualSyncDate = syncSettings.lastManualSyncDate {
                HStack(spacing: EnsembleDesign.Spacing.sm) {
                    Image(systemName: EnsembleDesign.Icon.recentPlaylist)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                    Text("Last manual sync \(formattedTimestamp(lastManualSyncDate))")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }
        .padding(.vertical, EnsembleDesign.Spacing.xxs)
    }

    private var profileStatusRow: some View {
        let presentation = profileStatusPresentation
        return VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs + EnsembleDesign.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: EnsembleDesign.Spacing.md) {
                Label(presentation.title, systemImage: presentation.symbolName)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                Spacer()
                Text(presentation.status)
                    .font(EnsembleScaffold.SyncSettings.statusFont)
                    .foregroundColor(presentation.tint)
            }

            Text(presentation.detail)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            if let timestamp = presentation.timestamp {
                Text("Updated \(formattedTimestamp(timestamp))")
                    .font(EnsembleScaffold.SyncSettings.timestampFont)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
        .padding(.vertical, EnsembleScaffold.SyncSettings.rowVerticalPadding)
    }

    private func featureRow(for feature: SyncSettingsManager.SyncFeature) -> some View {
        let presentation = featureStatusPresentation(for: feature)
        let isToggleable = syncSettings.isFeatureToggleable(feature)

        return VStack(alignment: .leading, spacing: EnsembleScaffold.SyncSettings.rowStatusSpacing) {
            Toggle(isOn: Binding(
                get: { syncSettings.rawToggleValue(feature) },
                set: { syncSettings.setFeatureEnabled(feature, enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                    Text(feature.displayName)
                    Text(feature.subtitle)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
            .disabled(!isToggleable)

            HStack(alignment: .top, spacing: EnsembleDesign.Spacing.sm) {
                Image(systemName: presentation.symbolName)
                    .foregroundColor(presentation.tint)
                    .frame(width: EnsembleScaffold.SyncSettings.iconLaneWidth)

                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                    Text(presentation.status)
                        .font(EnsembleScaffold.SyncSettings.statusFont)
                        .foregroundColor(presentation.tint)

                    Text(presentation.detail)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)

                    if !isToggleable, let dependencyMessage = dependencyMessage(for: feature) {
                        Text(dependencyMessage)
                            .font(EnsembleScaffold.SyncSettings.timestampFont)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    } else if let timestamp = presentation.timestamp {
                        Text("Updated \(formattedTimestamp(timestamp))")
                            .font(EnsembleScaffold.SyncSettings.timestampFont)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
            }
        }
        .padding(.vertical, EnsembleScaffold.SyncSettings.rowVerticalPadding)
    }

    private func dependencyMessage(for feature: SyncSettingsManager.SyncFeature) -> String? {
        switch feature {
        case .libraries where !syncSettings.rawToggleValue(.sources):
            return "Enable Sources on this device to sync library selection."
        default:
            return nil
        }
    }

    private var profileStatusPresentation: StatusPresentation {
        let status = syncSettings.profileStatus
        switch status.phase {
        case .unknown:
            return StatusPresentation(
                id: "profile",
                title: "Profile",
                symbolName: EnsembleDesign.Icon.profile,
                status: "Not Checked",
                detail: status.detail,
                tint: EnsembleDesign.Color.secondaryText,
                timestamp: status.date
            )

        case .noRecord:
            return StatusPresentation(
                id: "profile",
                title: "Profile",
                symbolName: EnsembleDesign.Icon.profile,
                status: "No Cloud Record",
                detail: status.detail,
                tint: EnsembleDesign.Color.secondaryText,
                timestamp: status.date
            )

        case .transport(let transportState):
            return StatusPresentation(
                id: "profile",
                title: "Profile",
                symbolName: EnsembleDesign.Icon.profile,
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
                tint: EnsembleDesign.Color.secondaryText,
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
                tint: activity == nil ? EnsembleDesign.Color.secondaryText : EnsembleScaffold.SyncSettings.successTint,
                timestamp: activity?.date
            )

        case .bootstrapping:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Checking iCloud",
                detail: "Refreshing the latest value from iCloud.",
                tint: EnsembleDesign.Color.secondaryText,
                timestamp: activity?.date
            )

        case .appliedRemote:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: activity.flatMap(statusText(for:)) ?? "Pulled from iCloud",
                detail: activity?.detail ?? "Applied the latest value from iCloud.",
                tint: EnsembleScaffold.SyncSettings.successTint,
                timestamp: activity?.date
            )

        case .seededLocal:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: activity.flatMap(statusText(for:)) ?? "Pushed from This Device",
                detail: activity?.detail ?? "Uploaded the local value to iCloud.",
                tint: EnsembleScaffold.SyncSettings.successTint,
                timestamp: activity?.date
            )

        case .waitingForTransport:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Waiting for iCloud",
                detail: "The iCloud key-value store has not delivered this feature yet.",
                tint: EnsembleDesign.Color.warning,
                timestamp: activity?.date
            )

        case .transportUnavailable:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "iCloud Unavailable",
                detail: "This device cannot reach iCloud key-value sync right now.",
                tint: EnsembleDesign.Color.warning,
                timestamp: activity?.date
            )

        case .error:
            return StatusPresentation(
                id: feature.id,
                title: feature.displayName,
                symbolName: symbolName(for: feature),
                status: "Error",
                detail: activity?.detail ?? "Sync hit an error for this feature.",
                tint: EnsembleDesign.Color.destructive,
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
        case .unavailable:
            return "Unavailable"
        case .error:
            return "Error"
        }
    }

    private func profileTint(for state: CloudSyncService.ProfileTransportState) -> Color {
        switch state {
        case .available:
            return EnsembleScaffold.SyncSettings.successTint
        case .unknown:
            return EnsembleDesign.Color.secondaryText
        case .notAuthenticated, .networkUnavailable, .rateLimited:
            return EnsembleDesign.Color.warning
        case .quotaExceeded, .unavailable, .error:
            return EnsembleDesign.Color.destructive
        }
    }

    private func symbolName(for feature: SyncSettingsManager.SyncFeature) -> String {
        switch feature {
        case .sources:
            return EnsembleDesign.Icon.playlist
        case .libraries:
            return EnsembleDesign.Icon.libraryStack
        case .pins:
            return EnsembleDesign.Icon.pin
        case .hiddenItems:
            return "eye.slash"
        case .accentColor:
            return EnsembleDesign.Icon.paintPalette
        case .swipeActions:
            return EnsembleDesign.Icon.tapGesture
        case .merging:
            return EnsembleDesign.Icon.merge
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
