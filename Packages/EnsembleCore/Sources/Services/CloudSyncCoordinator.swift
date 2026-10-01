import CloudKit
import Combine
import EnsembleAPI
import EnsembleDomain
import Foundation

/// Owns profile and feature reconciliation, bounded bootstrap retries, and cloud callbacks.
@MainActor
final class CloudSyncCoordinator {
    private let userProfileStore: UserProfileStore
    private let cloudSyncService: CloudSyncService
    private let syncSettingsManager: SyncSettingsManager
    private let kvsSyncService: KVSSyncService
    private let settingsManager: SettingsManager
    private let pinManager: PinManager
    private let hiddenMediaStore: HiddenMediaStore
    private let accountManager: AccountManager
    private let accountDiscoveryService: PlexAccountDiscoveryService
    private let syncCoordinator: SyncCoordinator
    private var kvsSyncCancellables = Set<AnyCancellable>()
    private var lastSyncedAccentColor: String = AppAccentColor.blue.rawValue
    private var lastSyncedSwipeLayout: TrackSwipeLayout = .default
    private var lastSyncedMergingPreferences = EnsembleMergingPreferences.default
    private var lastSyncedPinsData: Data?
    private var syncBootstrapTask: Task<Void, Never>?
    private var firstConnectRetryTask: Task<Void, Never>?
    private var firstConnectRetryAttempt = 0
    private var lastKnownICloudAccountStatus: CKAccountStatus = .couldNotDetermine
    private var lastKnownProfileTransportState: CloudSyncService.ProfileTransportState = .unknown
    private static let firstConnectRetryDelays: [TimeInterval] = [5, 15, 30, 60]

    init(
        userProfileStore: UserProfileStore,
        cloudSyncService: CloudSyncService,
        syncSettingsManager: SyncSettingsManager,
        kvsSyncService: KVSSyncService,
        settingsManager: SettingsManager,
        pinManager: PinManager,
        hiddenMediaStore: HiddenMediaStore,
        accountManager: AccountManager,
        accountDiscoveryService: PlexAccountDiscoveryService,
        syncCoordinator: SyncCoordinator
    ) {
        self.userProfileStore = userProfileStore
        self.cloudSyncService = cloudSyncService
        self.syncSettingsManager = syncSettingsManager
        self.kvsSyncService = kvsSyncService
        self.settingsManager = settingsManager
        self.pinManager = pinManager
        self.hiddenMediaStore = hiddenMediaStore
        self.accountManager = accountManager
        self.accountDiscoveryService = accountDiscoveryService
        self.syncCoordinator = syncCoordinator
        lastSyncedAccentColor = settingsManager.accentColorName
        lastSyncedSwipeLayout = settingsManager.trackSwipeLayout
        lastSyncedMergingPreferences = settingsManager.mergingPreferences
        lastSyncedPinsData = pinManager.exportPinsData()
    }

    deinit {
        syncBootstrapTask?.cancel()
        firstConnectRetryTask?.cancel()
    }

    func wireCallbacks() {
        wireProfileAndCloudCallbacks()
        wireKVSSyncCallbacks()
    }

    private func wireProfileAndCloudCallbacks() {
        userProfileStore.onProfileUpdated = { [weak userProfileStore, weak cloudSyncService, weak syncSettingsManager] profile in
            let imageData = userProfileStore?.getProfileImageData()
            Task {
                await cloudSyncService?.pushProfile(profile, imageData: imageData)
                let transportState = await cloudSyncService?.currentProfileTransportState() ?? .unknown
                await MainActor.run {
                    syncSettingsManager?.setProfileStatus(
                        phase: .transport(transportState),
                        direction: .pushedFromThisDevice,
                        detail: "Pushed profile changes from this device."
                    )
                }
            }
        }

        let profileStore = userProfileStore
        let hiddenStore = hiddenMediaStore
        let syncSettings = syncSettingsManager
        Task { [weak cloudSyncService] in
            await cloudSyncService?.setRemoteChangeHandler { [profileStore] profile, imageData in
                await MainActor.run {
                    profileStore.applyRemoteProfile(profile, imageData: imageData)
                    syncSettings.setProfileStatus(
                        phase: .transport(.available),
                        direction: .pulledFromICloud,
                        detail: "Pulled profile changes from iCloud."
                    )
                }
            }
            await cloudSyncService?.setHiddenMediaChangeHandler { [hiddenStore, syncSettings] mutations in
                await MainActor.run {
                    guard syncSettings.isFeatureEnabled(.hiddenItems) else { return }
                    hiddenStore.applyRemote(mutations)
                    syncSettings.recordFeatureActivity(
                        for: .hiddenItems,
                        state: .appliedRemote,
                        direction: .pulledFromICloud,
                        detail: "Pulled hidden items from iCloud."
                    )
                }
            }
            await cloudSyncService?.subscribeToChanges()
        }

        hiddenMediaStore.$snapshot
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak hiddenMediaStore, weak cloudSyncService, weak syncSettingsManager] _ in
                guard let hiddenMediaStore, let cloudSyncService, let syncSettingsManager else { return }
                guard syncSettingsManager.isFeatureEnabled(.hiddenItems) else { return }
                if let lastApply = hiddenMediaStore.lastRemoteApplyTime,
                   Date().timeIntervalSince(lastApply) < 2 { return }
                let mutations = hiddenMediaStore.exportMutations()
                Task {
                    guard let merged = await cloudSyncService.pushHiddenMedia(mutations) else { return }
                    await MainActor.run {
                        hiddenMediaStore.applyRemote(merged)
                        syncSettingsManager.recordFeatureActivity(
                            for: .hiddenItems,
                            state: .seededLocal,
                            direction: .pushedFromThisDevice,
                            detail: "Pushed hidden items from this device."
                        )
                    }
                }
            }
            .store(in: &kvsSyncCancellables)
    }

    private func wireKVSSyncCallbacks() {
        let settings = settingsManager
        let kvs = kvsSyncService
        let syncToggles = syncSettingsManager
        let pins = pinManager
        let acctMgr = accountManager
        let discovery = accountDiscoveryService

        kvsSyncService.onRemoteAccentColorChanged = { [weak self] colorName in
            guard let self else { return }
            guard syncToggles.isFeatureEnabled(.accentColor) else { return }
            self.lastSyncedAccentColor = colorName
            syncToggles.recordFeatureActivity(
                for: .accentColor,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled accent color from iCloud."
            )
            guard settings.accentColorName != colorName else { return }
            settings.setAccentColor(AppAccentColor(rawValue: colorName) ?? .blue)
        }

        kvsSyncService.onRemoteSwipeLayoutChanged = { [weak self] data in
            guard let self else { return }
            guard syncToggles.isFeatureEnabled(.swipeActions) else { return }
            guard let layout = try? JSONDecoder().decode(TrackSwipeLayout.self, from: data) else { return }
            self.lastSyncedSwipeLayout = layout
            syncToggles.recordFeatureActivity(
                for: .swipeActions,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled swipe actions from iCloud."
            )
            guard settings.trackSwipeLayout != layout else { return }
            settings.trackSwipeLayout = layout
        }

        kvsSyncService.onRemoteMergingPreferencesChanged = { [weak self] data in
            guard let self else { return }
            guard syncToggles.isFeatureEnabled(.merging) else { return }
            guard let preferences = try? JSONDecoder().decode(EnsembleMergingPreferences.self, from: data) else { return }
            self.lastSyncedMergingPreferences = preferences
            syncToggles.recordFeatureActivity(
                for: .merging,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled merging preferences from iCloud."
            )
            settings.setMergingPreferences(preferences)
        }

        settings.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self, weak settings, weak kvs, weak syncToggles] _ in
                guard let self, let settings, let kvs, let syncToggles else { return }
                if syncToggles.isFeatureEnabled(.accentColor),
                   settings.accentColorName != self.lastSyncedAccentColor {
                    self.lastSyncedAccentColor = settings.accentColorName
                    syncToggles.recordFeatureActivity(
                        for: .accentColor,
                        state: .seededLocal,
                        direction: .pushedFromThisDevice,
                        detail: "Pushed accent color from this device."
                    )
                    kvs.pushString(settings.accentColorName, forKey: KVSSyncService.KVSKey.accentColor)
                }

                if syncToggles.isFeatureEnabled(.swipeActions) {
                    let currentLayout = settings.trackSwipeLayout
                    if currentLayout != self.lastSyncedSwipeLayout {
                        self.lastSyncedSwipeLayout = currentLayout
                        syncToggles.recordFeatureActivity(
                            for: .swipeActions,
                            state: .seededLocal,
                            direction: .pushedFromThisDevice,
                            detail: "Pushed swipe actions from this device."
                        )
                        if let data = try? JSONEncoder().encode(currentLayout) {
                            kvs.pushData(data, forKey: KVSSyncService.KVSKey.swipeLayout)
                        }
                    }
                }

                guard syncToggles.isFeatureEnabled(.merging) else { return }
                let preferences = settings.mergingPreferences
                guard preferences != self.lastSyncedMergingPreferences,
                      let data = try? JSONEncoder().encode(preferences) else { return }
                self.lastSyncedMergingPreferences = preferences
                syncToggles.recordFeatureActivity(
                    for: .merging,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed merging preferences from this device."
                )
                kvs.pushData(data, forKey: KVSSyncService.KVSKey.mergingPreferences)
                }
            .store(in: &kvsSyncCancellables)

        kvsSyncService.onRemotePinsChanged = { [weak self, weak pins] data in
            guard let self, let pins else { return }
            guard syncToggles.isFeatureEnabled(.pins) else { return }
            self.lastSyncedPinsData = data
            syncToggles.recordFeatureActivity(
                for: .pins,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled pins from iCloud."
            )
            if let remotePins = try? JSONDecoder().decode([PinnedItem].self, from: data) {
                pins.applyRemotePins(remotePins)
            }
        }

        pins.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self, weak pins, weak kvs, weak syncToggles] _ in
                guard let self, let pins, let kvs, let syncToggles else { return }
                guard syncToggles.isFeatureEnabled(.pins) else { return }
                if let lastApply = pins.lastRemoteApplyTime,
                   Date().timeIntervalSince(lastApply) < 2.0 {
                    return
                }
                guard let data = pins.exportPinsData(), data != self.lastSyncedPinsData else { return }
                self.lastSyncedPinsData = data
                syncToggles.recordFeatureActivity(
                    for: .pins,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed pins from this device."
                )
                kvs.pushData(data, forKey: KVSSyncService.KVSKey.pins)
            }
            .store(in: &kvsSyncCancellables)

        acctMgr.onNewAccountsFromSync = { [weak self, weak acctMgr, weak syncToggles] newCredentials in
            guard let self, let acctMgr, let syncToggles else { return }
            guard syncToggles.isFeatureEnabled(.sources) else { return }
            syncToggles.recordFeatureActivity(
                for: .sources,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled sources from iCloud."
            )

            for credential in newCredentials {
                Task {
                    do {
                        let result = try await discovery.discoverAccount(authToken: credential.authToken)
                        await MainActor.run {
                            var config = PlexAccountConfig(
                                id: credential.accountId,
                                email: credential.email,
                                plexUsername: credential.plexUsername,
                                displayTitle: credential.displayTitle,
                                authToken: credential.authToken,
                                servers: result.servers
                            )
                            config = acctMgr.applyingCredentialLibrarySelection(to: config, credential: credential)
                            if syncToggles.isFeatureEnabled(.libraries) {
                                config = acctMgr.applyingSyncedLibraryFlags(to: config)
                            }
                            acctMgr.addPlexAccount(config)
                            acctMgr.setAwaitingCloudSources(false)
                            self.syncCoordinator.refreshProviders()
                            EnsembleLogger.info("Sync: discovered account \(credential.accountId) with \(result.servers.count) servers")

                            let enabledSources = config.servers.flatMap { server in
                                server.libraries.compactMap { library -> MusicSourceIdentifier? in
                                    guard library.isEnabled else { return nil }
                                    return MusicSourceIdentifier(
                                        type: .plex,
                                        accountId: config.id,
                                        serverId: server.id,
                                        libraryId: library.key
                                    )
                                }
                            }

                            if !enabledSources.isEmpty {
                                Task {
                                    await self.syncCoordinator.sync(sources: enabledSources)
                                }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            syncToggles.recordFeatureActivity(
                                for: .sources,
                                state: .error,
                                direction: nil,
                                detail: "Failed to pull sources from iCloud."
                            )
                        }
                        EnsembleLogger.error("Sync: failed to discover account \(credential.accountId): \(error)")
                    }
                }
            }
        }

        kvsSyncService.onRemoteLibraryFlagsChanged = { [weak self, weak acctMgr] data in
            guard let self, let acctMgr else { return }
            guard syncToggles.isFeatureEnabled(.libraries) else { return }
            Task { @MainActor in
                let result = acctMgr.applyLibraryFlags(data)
                syncToggles.recordFeatureActivity(
                    for: .libraries,
                    state: .appliedRemote,
                    direction: .pulledFromICloud,
                    detail: "Pulled library selection from iCloud."
                )

                if !acctMgr.hasAnySources && !syncToggles.hasCompletedFirstConnect {
                    self.scheduleSyncBootstrap(reason: "remote-library-flags", feature: .sources)
                }

                guard result.hasChanges else { return }

                self.syncCoordinator.refreshProviders()

                let disabledSourcesToCleanup = Array(Set(result.disabledSources))
                if !disabledSourcesToCleanup.isEmpty {
                    for source in disabledSourcesToCleanup {
                        EnsembleLogger.info(
                            "[SourceReconciliation] Cleanup requested source=\(source.compositeKey) reason=icloud-library-disabled"
                        )
                    }
                    await self.syncCoordinator.cleanupRemovedSourcesIfPresent(disabledSourcesToCleanup)
                }

                for server in result.serversNeedingPlaylistCleanup {
                    await self.syncCoordinator.cleanupServerPlaylists(
                        accountId: server.accountId,
                        serverId: server.serverId
                    )
                }

                if !result.enabledSources.isEmpty {
                    await self.syncCoordinator.sync(sources: result.enabledSources)
                }
            }
        }

        acctMgr.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak acctMgr, weak kvs, weak syncToggles] _ in
                guard let acctMgr, let kvs, let syncToggles else { return }
                guard syncToggles.isFeatureEnabled(.libraries) else { return }
                if let data = acctMgr.exportLibraryFlags() {
                    syncToggles.recordFeatureActivity(
                        for: .libraries,
                        state: .seededLocal,
                        direction: .pushedFromThisDevice,
                        detail: "Pushed library selection from this device."
                    )
                    kvs.pushData(data, forKey: KVSSyncService.KVSKey.libraryFlags)
                }
            }
            .store(in: &kvsSyncCancellables)

        kvsSyncService.onInitialSyncCompleted = { [weak self, weak syncToggles] in
            guard let self, let syncToggles else { return }
            guard syncToggles.isMasterSyncEnabled, !syncToggles.hasCompletedFirstConnect else { return }
            self.scheduleSyncBootstrap(reason: "kvs-initial-sync")
        }

        syncSettingsManager.onMasterSyncEnabled = { [weak self] in
            self?.scheduleSyncBootstrap(reason: "master-enabled")
        }

        syncSettingsManager.onFeatureReEnabled = { [weak self] feature in
            self?.scheduleSyncBootstrap(reason: "feature-reenabled", feature: feature)
        }
    }

    func reconcileSyncOnForeground() async {
        await refreshSyncState(reason: "foreground")
    }

    func runManualSync() async {
        syncSettingsManager.beginManualSync()
        defer { syncSettingsManager.finishManualSync() }
        await refreshSyncState(reason: "manual")
    }

    func refreshSyncState(
        reason: String,
        feature: SyncSettingsManager.SyncFeature? = nil,
        retryUnsettledOnly: Bool = false
    ) async {
        var shouldReconcileProfile = !retryUnsettledOnly
        if syncSettingsManager.isMasterSyncEnabled {
            lastKnownProfileTransportState = await cloudSyncService.currentProfileTransportState()
            lastKnownICloudAccountStatus = await cloudSyncService.currentAccountStatus()
            if retryUnsettledOnly {
                shouldReconcileProfile = profileNeedsRetry
            }
            await performSyncBootstrap(
                reason: reason,
                features: retryUnsettledOnly
                    ? syncSettingsManager.enabledFeaturesNeedingRetry
                    : feature.map { [$0] }
            )
        }

        if shouldReconcileProfile {
            await reconcileProfileSync(reason: reason)
        }
        scheduleFirstConnectRetryIfNeeded(reason: reason)
    }

    private func reconcileProfileSync(reason: String) async {
        if let remote = await cloudSyncService.pullProfile() {
            userProfileStore.applyRemoteProfile(remote.profile, imageData: remote.imageData)
            syncSettingsManager.setProfileStatus(
                phase: .transport(.available),
                direction: .pulledFromICloud,
                detail: "Pulled profile from iCloud."
            )
            return
        }

        let transportState = await resolvedProfileTransportState()
        guard transportState == .available else {
            syncSettingsManager.setProfileStatus(
                phase: .transport(transportState),
                direction: nil,
                detail: profileTransportDetail(for: transportState)
            )
            return
        }

        guard !userProfileStore.profile.isEmpty else {
            let status = Self.missingProfileStatusForEmptyLocalProfile(
                shouldKeepFirstConnectPending: shouldKeepFirstConnectPending
            )
            syncSettingsManager.setProfileStatus(
                phase: status.phase,
                direction: status.direction,
                detail: status.detail
            )
            return
        }

        EnsembleLogger.info("Sync profile: seeding local profile after \(reason)")
        await cloudSyncService.pushProfile(
            userProfileStore.profile,
            imageData: userProfileStore.getProfileImageData()
        )

        let updatedTransportState = await cloudSyncService.currentProfileTransportState()
        syncSettingsManager.setProfileStatus(
            phase: .transport(updatedTransportState),
            direction: updatedTransportState == .available ? .pushedFromThisDevice : nil,
            detail: updatedTransportState == .available
                ? "Pushed local profile to iCloud."
                : profileTransportDetail(for: updatedTransportState)
        )
    }

    private func resolvedProfileTransportState() async -> CloudSyncService.ProfileTransportState {
        let transportState = await cloudSyncService.currentProfileTransportState()
        guard transportState == .notAuthenticated else {
            return transportState
        }

        switch await cloudSyncService.currentAccountStatus() {
        case .available:
            return .available
        case .noAccount, .restricted:
            return .notAuthenticated
        case .temporarilyUnavailable, .couldNotDetermine:
            return .error
        @unknown default:
            return .error
        }
    }

    private func profileTransportDetail(
        for state: CloudSyncService.ProfileTransportState
    ) -> String {
        switch state {
        case .unknown:
            return "Profile sync has not run yet."
        case .available:
            return "CloudKit is available."
        case .notAuthenticated:
            return "Sign in to iCloud and enable iCloud Drive to sync the profile."
        case .networkUnavailable:
            return "Profile sync is waiting for a network connection."
        case .quotaExceeded:
            return "iCloud storage is full for profile sync."
        case .rateLimited:
            return "CloudKit rate-limited the profile sync. Try again shortly."
        case .unavailable:
            return "Profile sync is unavailable in this build."
        case .error:
            return "Profile sync could not confirm iCloud status right now."
        }
    }

    private func scheduleSyncBootstrap(reason: String, feature: SyncSettingsManager.SyncFeature? = nil) {
        syncBootstrapTask?.cancel()
        syncBootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSyncState(reason: reason, feature: feature)
        }
    }

    private var shouldKeepFirstConnectPending: Bool {
        !syncSettingsManager.hasCompletedFirstConnect &&
        firstConnectRetryAttempt < Self.firstConnectRetryDelays.count
    }

    private var needsFirstConnectRetry: Bool {
        guard firstConnectRetryAttempt < Self.firstConnectRetryDelays.count else { return false }
        if !syncSettingsManager.enabledFeaturesNeedingRetry.isEmpty {
            return true
        }

        let waitingForSources =
            Self.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: syncSettingsManager.isFeatureEnabled(.sources),
                hasAnySources: accountManager.hasAnySources,
                hasSyncedCloudCredentials: accountManager.hasSyncedCloudCredentials(),
                accountStatus: lastKnownICloudAccountStatus,
                profileTransportState: lastKnownProfileTransportState
            )

        return waitingForSources || profileNeedsRetry
    }

    private var profileNeedsRetry: Bool {
        switch syncSettingsManager.profileStatus.phase {
        case .transport(.networkUnavailable), .transport(.rateLimited), .transport(.error):
            return true
        case .unknown:
            return !syncSettingsManager.hasCompletedFirstConnect &&
                userProfileStore.profile.isEmpty &&
                !Self.isBootstrapTransportUnavailable(
                    accountStatus: lastKnownICloudAccountStatus,
                    profileTransportState: lastKnownProfileTransportState
                )
        case .noRecord, .transport:
            return false
        }
    }

    private func scheduleFirstConnectRetryIfNeeded(reason: String) {
        guard syncSettingsManager.isMasterSyncEnabled else {
            firstConnectRetryTask?.cancel()
            firstConnectRetryTask = nil
            firstConnectRetryAttempt = 0
            return
        }

        guard needsFirstConnectRetry else {
            firstConnectRetryTask?.cancel()
            firstConnectRetryTask = nil
            firstConnectRetryAttempt = 0
            return
        }

        guard firstConnectRetryTask == nil else { return }
        let attemptNumber = firstConnectRetryAttempt + 1
        let delay = Self.firstConnectRetryDelays[firstConnectRetryAttempt]
        firstConnectRetryAttempt += 1

        EnsembleLogger.info(
            "Sync bootstrap: scheduling retry \(attemptNumber)/\(Self.firstConnectRetryDelays.count) in \(Int(delay))s after \(reason)"
        )

        firstConnectRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            self.firstConnectRetryTask = nil
            await self.refreshSyncState(
                reason: "sync-retry-\(attemptNumber)",
                retryUnsettledOnly: true
            )
        }
    }

    private func performSyncBootstrap(
        reason: String,
        features: [SyncSettingsManager.SyncFeature]? = nil
    ) async {
        guard syncSettingsManager.isMasterSyncEnabled else { return }

        let featuresToBootstrap = features ?? SyncSettingsManager.SyncFeature.allCases.filter {
            syncSettingsManager.isFeatureEnabled($0)
        }

        for feature in featuresToBootstrap {
            guard !Task.isCancelled else { return }
            _ = await bootstrapFeature(feature, reason: reason)
        }

        guard !syncSettingsManager.hasCompletedFirstConnect else { return }
        guard enabledFeaturesAreSettled else { return }

        EnsembleLogger.info("Sync bootstrap: first-connect settled after \(reason)")
        syncSettingsManager.markFirstConnectComplete()
    }

    private var enabledFeaturesAreSettled: Bool {
        SyncSettingsManager.SyncFeature.allCases
            .filter { syncSettingsManager.isFeatureEnabled($0) }
            .allSatisfy { feature in
                switch syncSettingsManager.featureState(for: feature) {
                case .idle, .appliedRemote, .seededLocal, .transportUnavailable:
                    return true
                case .bootstrapping, .waitingForTransport, .error:
                    return false
                }
            }
    }

    @discardableResult
    private func bootstrapFeature(
        _ feature: SyncSettingsManager.SyncFeature,
        reason: String
    ) async -> Bool {
        switch feature {
        case .accentColor:
            return await bootstrapAccentColor(reason: reason)
        case .swipeActions:
            return await bootstrapSwipeActions(reason: reason)
        case .merging:
            return await bootstrapMergingPreferences(reason: reason)
        case .pins:
            return await bootstrapPins(reason: reason)
        case .hiddenItems:
            return await bootstrapHiddenMedia(reason: reason)
        case .sources:
            return bootstrapSources(reason: reason)
        case .libraries:
            return await bootstrapLibraryFlags(reason: reason)
        }
    }

    private func bootstrapSources(reason: String) -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.sources) else {
            syncSettingsManager.setFeatureState(.idle, for: .sources)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .sources)

        if accountManager.hasSyncedCloudCredentials() {
            accountManager.setAwaitingCloudSources(false)
            let newAccounts = accountManager.pullSyncCredentials()
            syncSettingsManager.recordFeatureActivity(
                for: .sources,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled sources from iCloud."
            )
            if !newAccounts.isEmpty {
                accountManager.onNewAccountsFromSync?(newAccounts)
            }
            return true
        }

        guard accountManager.hasAnySources else {
            if Self.isBootstrapTransportUnavailable(
                accountStatus: lastKnownICloudAccountStatus,
                profileTransportState: lastKnownProfileTransportState
            ) {
                accountManager.setAwaitingCloudSources(false)
                syncSettingsManager.setFeatureState(.transportUnavailable, for: .sources)
                return true
            }

            if shouldKeepFirstConnectPending {
                accountManager.setAwaitingCloudSources(true)
                EnsembleLogger.info("Sync bootstrap: waiting for iCloud sources after \(reason)")
                syncSettingsManager.setFeatureState(.waitingForTransport, for: .sources)
                return false
            }

            accountManager.setAwaitingCloudSources(false)
            syncSettingsManager.setFeatureState(.idle, for: .sources)
            return true
        }

        accountManager.setAwaitingCloudSources(false)
        EnsembleLogger.info("Sync bootstrap: seeding local sources after \(reason)")
        accountManager.seedCloudSyncCredentialsFromLocal()
        syncSettingsManager.recordFeatureActivity(
            for: .sources,
            state: .seededLocal,
            direction: .pushedFromThisDevice,
            detail: "Pushed sources from this device."
        )
        return true
    }

    /// All KVS features share the same pull-before-seed and initial-sync boundary.
    private func bootstrapKVSFeature<Value>(
        _ feature: SyncSettingsManager.SyncFeature,
        reason: String,
        label: String,
        readRemote: () -> Value?,
        applyRemote: (Value) -> Void,
        seedLocal: () -> Bool
    ) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(feature) else {
            syncSettingsManager.setFeatureState(.idle, for: feature)
            return true
        }
        guard kvsSyncService.isAvailable else {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: feature)
            return true
        }
        syncSettingsManager.setFeatureState(.bootstrapping, for: feature)
        kvsSyncService.synchronize()
        if let value = readRemote() {
            applyRemote(value)
            return true
        }
        if Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus) {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: feature)
            return true
        }
        let didSettleInitialSync = await kvsSyncService.waitForInitialSync()
        if let value = readRemote() {
            applyRemote(value)
            return true
        }
        guard didSettleInitialSync else {
            EnsembleLogger.info("Sync bootstrap: waiting for KVS \(label) after \(reason)")
            syncSettingsManager.setFeatureState(.waitingForTransport, for: feature)
            return false
        }
        return seedLocal()
    }

    private func bootstrapAccentColor(reason: String) async -> Bool {
        await bootstrapKVSFeature(
            .accentColor,
            reason: reason,
            label: "accent color",
            readRemote: { kvsSyncService.pullString(forKey: KVSSyncService.KVSKey.accentColor) },
            applyRemote: { kvsSyncService.onRemoteAccentColorChanged?($0) },
            seedLocal: {
                lastSyncedAccentColor = settingsManager.accentColorName
                EnsembleLogger.info("Sync bootstrap: seeding local accent color after \(reason)")
                syncSettingsManager.recordFeatureActivity(
                    for: .accentColor,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed accent color from this device."
                )
                kvsSyncService.pushString(settingsManager.accentColorName, forKey: KVSSyncService.KVSKey.accentColor)
                return true
            }
        )
    }

    private func bootstrapSwipeActions(reason: String) async -> Bool {
        await bootstrapKVSFeature(
            .swipeActions,
            reason: reason,
            label: "swipe layout",
            readRemote: { kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.swipeLayout) },
            applyRemote: { kvsSyncService.onRemoteSwipeLayoutChanged?($0) },
            seedLocal: {
                lastSyncedSwipeLayout = settingsManager.trackSwipeLayout
                guard let data = try? JSONEncoder().encode(settingsManager.trackSwipeLayout) else {
                    syncSettingsManager.setFeatureState(.error, for: .swipeActions)
                    return false
                }

                EnsembleLogger.info("Sync bootstrap: seeding local swipe layout after \(reason)")
                syncSettingsManager.recordFeatureActivity(
                    for: .swipeActions,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed swipe actions from this device."
                )
                kvsSyncService.pushData(data, forKey: KVSSyncService.KVSKey.swipeLayout)
                return true
            }
        )
    }

    private func bootstrapMergingPreferences(reason: String) async -> Bool {
        await bootstrapKVSFeature(
            .merging,
            reason: reason,
            label: "merging preferences",
            readRemote: { kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.mergingPreferences) },
            applyRemote: { kvsSyncService.onRemoteMergingPreferencesChanged?($0) },
            seedLocal: {
                guard let data = try? JSONEncoder().encode(settingsManager.mergingPreferences) else {
                    syncSettingsManager.setFeatureState(.waitingForTransport, for: .merging)
                    return false
                }

                lastSyncedMergingPreferences = settingsManager.mergingPreferences
                EnsembleLogger.info("Sync bootstrap: seeding local merging preferences after \(reason)")
                syncSettingsManager.recordFeatureActivity(
                    for: .merging,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed merging preferences from this device."
                )
                kvsSyncService.pushData(data, forKey: KVSSyncService.KVSKey.mergingPreferences)
                return true
            }
        )
    }

    private func bootstrapPins(reason: String) async -> Bool {
        await bootstrapKVSFeature(
            .pins,
            reason: reason,
            label: "pins",
            readRemote: { kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.pins) },
            applyRemote: { kvsSyncService.onRemotePinsChanged?($0) },
            seedLocal: {
                guard !pinManager.pinnedItems.isEmpty, let data = pinManager.exportPinsData() else {
                    syncSettingsManager.setFeatureState(.idle, for: .pins)
                    return true
                }

                lastSyncedPinsData = data
                EnsembleLogger.info("Sync bootstrap: seeding local pins after \(reason)")
                syncSettingsManager.recordFeatureActivity(
                    for: .pins,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed pins from this device."
                )
                kvsSyncService.pushData(data, forKey: KVSSyncService.KVSKey.pins)
                return true
            }
        )
    }

    private func bootstrapHiddenMedia(reason: String) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.hiddenItems) else {
            syncSettingsManager.setFeatureState(.idle, for: .hiddenItems)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .hiddenItems)
        guard let remote = await cloudSyncService.pullHiddenMedia() else {
            EnsembleLogger.info("Sync bootstrap: waiting for CloudKit hidden items after \(reason)")
            syncSettingsManager.setFeatureState(.waitingForTransport, for: .hiddenItems)
            return false
        }

        EnsembleLogger.info("Sync bootstrap: pulled \(remote.count) hidden-item mutations after \(reason)")
        if !remote.isEmpty {
            hiddenMediaStore.applyRemote(remote)
            syncSettingsManager.recordFeatureActivity(
                for: .hiddenItems,
                state: .appliedRemote,
                direction: .pulledFromICloud,
                detail: "Pulled hidden items from iCloud."
            )
            if let merged = await cloudSyncService.pushHiddenMedia(hiddenMediaStore.exportMutations()) {
                hiddenMediaStore.applyRemote(merged)
            }
            return true
        }

        guard !hiddenMediaStore.exportMutations().isEmpty else {
            syncSettingsManager.setFeatureState(.idle, for: .hiddenItems)
            return true
        }
        guard let merged = await cloudSyncService.pushHiddenMedia(hiddenMediaStore.exportMutations()) else {
            syncSettingsManager.setFeatureState(.waitingForTransport, for: .hiddenItems)
            return false
        }
        hiddenMediaStore.applyRemote(merged)
        syncSettingsManager.recordFeatureActivity(
            for: .hiddenItems,
            state: .seededLocal,
            direction: .pushedFromThisDevice,
            detail: "Pushed hidden items from this device after \(reason)."
        )
        return true
    }

    private func bootstrapLibraryFlags(reason: String) async -> Bool {
        await bootstrapKVSFeature(
            .libraries,
            reason: reason,
            label: "library flags",
            readRemote: { kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.libraryFlags) },
            applyRemote: { kvsSyncService.onRemoteLibraryFlagsChanged?($0) },
            seedLocal: {
                guard accountManager.hasAnySources, let data = accountManager.exportLibraryFlags() else {
                    syncSettingsManager.setFeatureState(.idle, for: .libraries)
                    return true
                }

                EnsembleLogger.info("Sync bootstrap: seeding local library flags after \(reason)")
                syncSettingsManager.recordFeatureActivity(
                    for: .libraries,
                    state: .seededLocal,
                    direction: .pushedFromThisDevice,
                    detail: "Pushed library selection from this device."
                )
                kvsSyncService.pushData(data, forKey: KVSSyncService.KVSKey.libraryFlags)
                return true
            }
        )
    }

    nonisolated static func isBootstrapTransportUnavailable(
        accountStatus: CKAccountStatus,
        profileTransportState: CloudSyncService.ProfileTransportState = .unknown
    ) -> Bool {
        if profileTransportState == .unavailable {
            return true
        }

        switch accountStatus {
        case .noAccount, .restricted:
            return true
        default:
            return false
        }
    }

    nonisolated static func missingProfileStatusForEmptyLocalProfile(
        shouldKeepFirstConnectPending: Bool
    ) -> SyncSettingsManager.ProfileSyncStatus {
        if shouldKeepFirstConnectPending {
            return SyncSettingsManager.ProfileSyncStatus(
                phase: .unknown,
                direction: nil,
                detail: "Waiting for iCloud profile during first-device sync."
            )
        }

        return SyncSettingsManager.ProfileSyncStatus(
            phase: .unknown,
            direction: nil,
            detail: "No iCloud profile has been created yet."
        )
    }

    nonisolated static func shouldRetryFirstConnectForSources(
        sourcesFeatureEnabled: Bool,
        hasAnySources: Bool,
        hasSyncedCloudCredentials: Bool,
        accountStatus: CKAccountStatus,
        profileTransportState: CloudSyncService.ProfileTransportState = .unknown
    ) -> Bool {
        sourcesFeatureEnabled &&
        !hasAnySources &&
        !hasSyncedCloudCredentials &&
        !isBootstrapTransportUnavailable(
            accountStatus: accountStatus,
            profileTransportState: profileTransportState
        )
    }

}
