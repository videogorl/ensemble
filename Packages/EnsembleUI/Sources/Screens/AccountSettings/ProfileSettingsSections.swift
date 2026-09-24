import EnsembleDesignTokens
import EnsembleCore
import EnsembleDomain
import SwiftUI

// MARK: - Music Source Account Row

struct MusicSourceAccountRow: View {
    let sourceType: MusicSourceType
    let sourceName: String
    let accountIdentifier: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName)
                Text(accountIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(sourceType == .plex ? "PlexSourceIcon" : "AppleMusicSourceIcon")
                .resizable()
                .scaledToFit()
                .padding(sourceType == .plex ? 3 : 0)
                .frame(width: 30, height: 30)
                .background(sourceType == .plex ? Color.black : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(width: EnsembleScaffold.UtilityRow.iconLaneWidth)
        }
    }
}

// MARK: - Audio Quality Settings

struct AudioQualitySettingsView: View {
    @Environment(\.dependencies) private var deps
    @AppStorage(AudioQualityPreference.streamingQualityKey)
    private var streamingQuality = AudioQualityPreference.defaultStreamingQuality
    @AppStorage(AudioQualityPreference.allowStreamingOnCellularKey)
    private var allowStreamingOnCellular = AudioQualityPreference.defaultAllowStreamingOnCellular
    @AppStorage(AudioQualityPreference.downloadQualityKey)
    private var downloadQuality = AudioQualityPreference.defaultDownloadQuality
    @AppStorage(AudioQualityPreference.sharingQualityKey)
    private var sharingQuality = AudioQualityPreference.defaultSharingQuality
    @AppStorage(DownloadSettingsPreference.allowCellularDownloadsKey)
    private var allowCellularDownloads = DownloadSettingsPreference.defaultAllowCellularDownloads

    var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: "Audio Quality") {
            List {
                Section {
                    streamingQualityPicker
                    Toggle("Allow Streaming on Cellular", isOn: $allowStreamingOnCellular)
                } header: {
                    EnsembleUtilitySectionHeader("Streaming")
                } footer: {
                    Text("On Low Data Mode, downloaded Plex audio is preferred when available. Apple Music follows System Settings.")
                }

                Section {
                    downloadQualityPicker
                    Toggle("Allow Downloading on Cellular", isOn: $allowCellularDownloads)
                } header: {
                    EnsembleUtilitySectionHeader("Downloads")
                } footer: {
                    Text("Higher quality downloads use more storage space and cellular data.")
                }

                Section {
                    sharingQualityPicker
                } header: {
                    EnsembleUtilitySectionHeader("Sharing")
                } footer: {
                    Text("Controls audio files shared or dragged outside Ensemble.")
                }
            }
        } regularContent: {
            EnsembleUtilityCardSection(
                "Streaming",
                footer: "On Low Data Mode, downloaded Plex audio is preferred when available. Apple Music follows System Settings."
            ) {
                EnsembleUtilityCardRow {
                    streamingQualityPicker
                }

                EnsembleUtilityCardDivider()

                EnsembleUtilityCardRow {
                    Toggle("Allow Streaming on Cellular", isOn: $allowStreamingOnCellular)
                }
            }

            EnsembleUtilityCardSection(
                "Downloads",
                footer: "Higher quality downloads use more storage space and cellular data."
            ) {
                EnsembleUtilityCardRow {
                    downloadQualityPicker
                }

                EnsembleUtilityCardDivider()

                EnsembleUtilityCardRow {
                    Toggle("Allow Downloading on Cellular", isOn: $allowCellularDownloads)
                }
            }

            EnsembleUtilityCardSection(
                "Sharing",
                footer: "Controls audio files shared or dragged outside Ensemble."
            ) {
                EnsembleUtilityCardRow {
                    sharingQualityPicker
                }
            }
        }
        .onChange(of: allowStreamingOnCellular) { _ in
            NotificationCenter.default.post(name: AudioQualityPreference.cellularStreamingPolicyDidChange, object: nil)
        }
        .onChange(of: allowCellularDownloads) { _ in
            Task {
                await deps.offlineDownloadService.reevaluateQueuePolicy()
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

    private var sharingQualityPicker: some View {
        Picker("Sharing Quality", selection: $sharingQuality) {
            Text("Original").tag("original")
            Text("High (320 kbps)").tag("high")
            Text("Medium (192 kbps)").tag("medium")
            Text("Low (128 kbps)").tag("low")
        }
    }
}

// MARK: - SmartMix Settings

struct SmartMixSettingsView: View {
    private let playbackService = DependencyContainer.shared.playbackService
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    @State private var isSmartMixEnabled = DependencyContainer.shared.playbackService.isSmartMixEnabled
    @State private var isSmartMixDisabledForAlbums = DependencyContainer.shared.playbackService.isSmartMixDisabledForAlbums

    var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: "SmartMix") {
            List {
                Section {
                    smartMixToggle
                }

                Section {
                    albumToggle
                } footer: {
                    Text("Keep consecutive tracks from the same album gapless.")
                }

                if let notice = accountManager.smartMixCrossSourceNotice {
                    Section {} footer: {
                        Text(notice)
                    }
                }
            }
        } regularContent: {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
                EnsembleUtilityCardSection(nil) {
                    EnsembleUtilityCardRow {
                        smartMixToggle
                    }

                    EnsembleUtilityCardDivider()

                    EnsembleUtilityCardRow {
                        albumToggle
                    }
                }

                if let notice = accountManager.smartMixCrossSourceNotice {
                    Text(notice)
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }
        .onReceive(playbackService.smartMixEnabledPublisher) { isEnabled in
            guard isSmartMixEnabled != isEnabled else { return }
            isSmartMixEnabled = isEnabled
        }
        .onReceive(playbackService.smartMixDisabledForAlbumsPublisher) { isDisabled in
            guard isSmartMixDisabledForAlbums != isDisabled else { return }
            isSmartMixDisabledForAlbums = isDisabled
        }
    }

    private var smartMixToggle: some View {
        Toggle(isOn: Binding(
            get: { isSmartMixEnabled },
            set: playbackService.setSmartMixEnabled
        )) {
            EnsembleUtilityRowLabel(
                iconSystemName: EnsembleDesign.Icon.smartMix,
                title: "SmartMix",
                subtitle: "Blend compatible tracks together",
                iconColor: EnsembleDesign.Color.primaryText
            )
        }
    }

    private var albumToggle: some View {
        Toggle(isOn: Binding(
            get: { isSmartMixDisabledForAlbums },
            set: playbackService.setSmartMixDisabledForAlbums
        )) {
            EnsembleUtilityRowLabel(
                iconSystemName: "opticaldisc",
                title: "Disable for Albums",
                subtitle: "Don't mix consecutive tracks from the same album",
                iconColor: EnsembleDesign.Color.primaryText
            )
        }
        .disabled(!isSmartMixEnabled)
    }
}

// MARK: - Merging Settings

struct MergingSettingsView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: "Merging") {
            List {
                Section {
                    Toggle("Enable Merging", isOn: mergingBinding(\.isEnabled))
                }

                Section {
                    categoryToggles
                } footer: {
                    Text(mergingFooterText)
                }
            }
        } regularContent: {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
                EnsembleUtilityCardSection(nil) {
                    EnsembleUtilityCardRow {
                        Toggle("Enable Merging", isOn: mergingBinding(\.isEnabled))
                    }
                }

                EnsembleUtilityCardSection(nil, footer: mergingFooterText) {
                    EnsembleUtilityCardRow { categoryToggle("Artists", \.mergeArtists) }
                    EnsembleUtilityCardDivider()
                    EnsembleUtilityCardRow { categoryToggle("Albums", \.mergeAlbums) }
                    EnsembleUtilityCardDivider()
                    EnsembleUtilityCardRow { categoryToggle("Songs", \.mergeTracks) }
                    EnsembleUtilityCardDivider()
                    EnsembleUtilityCardRow { categoryToggle("Playlists", \.mergePlaylists) }
                }
            }
        }
    }

    @ViewBuilder
    private var categoryToggles: some View {
        categoryToggle("Artists", \.mergeArtists)
        categoryToggle("Albums", \.mergeAlbums)
        categoryToggle("Songs", \.mergeTracks)
        categoryToggle("Playlists", \.mergePlaylists)
    }

    private func categoryToggle(
        _ title: String,
        _ keyPath: WritableKeyPath<EnsembleMergingPreferences, Bool>
    ) -> some View {
        Toggle(title, isOn: mergingBinding(keyPath))
            .disabled(!settingsManager.mergingPreferences.isEnabled)
    }

    private var mergingFooterText: String {
        "Similar copies use your preferred library. Turn merging off to show every copy."
    }

    private func mergingBinding(
        _ keyPath: WritableKeyPath<EnsembleMergingPreferences, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settingsManager.mergingPreferences[keyPath: keyPath] },
            set: { value in
                settingsManager.updateMergingPreferences { $0[keyPath: keyPath] = value }
            }
        )
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
