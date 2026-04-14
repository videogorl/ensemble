import CloudKit
import EnsembleAPI
import EnsemblePersistence
import Combine
import Foundation

/// Central dependency container that creates and wires all services and view models
public final class DependencyContainer: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = DependencyContainer()

    // MARK: - Core Services

    public let keychain: KeychainServiceProtocol
    public let coreDataStack: CoreDataStack

    // MARK: - Multi-Source

    public let accountManager: AccountManager
    public let accountDiscoveryService: PlexAccountDiscoveryService
    public let syncCoordinator: SyncCoordinator

    // MARK: - Repositories

    public let libraryRepository: LibraryRepositoryProtocol
    public let playlistRepository: PlaylistRepositoryProtocol
    public let hubRepository: HubRepositoryProtocol
    public let moodRepository: MoodRepositoryProtocol
    public let downloadManager: DownloadManagerProtocol
    public let offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol
    public let artworkDownloadManager: ArtworkDownloadManagerProtocol

    // MARK: - Services

    public let networkMonitor: NetworkMonitor
    public let serverHealthChecker: ServerHealthChecker
    public let audioAnalyzer: AudioAnalyzerProtocol
    public let playbackService: PlaybackService
    public let artworkLoader: ArtworkLoaderProtocol
    public let settingsManager: SettingsManager
    public let cacheManager: CacheManager
    public let navigationCoordinator: NavigationCoordinator
    public let hubOrderManager: HubOrderManager
    public let pinManager: PinManager
    public let toastCenter: ToastCenter
    public let libraryVisibilityStore: LibraryVisibilityStore
    public let siriMediaIndexStore: SiriMediaIndexStore
    public let siriPlaybackCoordinator: SiriPlaybackCoordinator
    public let siriAffinityCoordinator: SiriAffinityCoordinator
    public let siriAddToPlaylistCoordinator: SiriAddToPlaylistCoordinator
    public let siriMediaUserContextManager: SiriMediaUserContextManager
    public let offlineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating
    public let offlineDownloadService: OfflineDownloadService
    public let lyricsService: LyricsService
    public let mutationCoordinator: MutationCoordinator
    public let metadataMutationService: MetadataMutationService
    public let songLinkService: SongLinkService
    public let shareService: ShareService
    public let powerStateMonitor: PowerStateMonitor
    public let persistentLogService: PersistentLogService

    // MARK: - Profile & Cloud Sync

    public let userProfileStore: UserProfileStore
    public let cloudSyncService: CloudSyncService
    public let syncSettingsManager: SyncSettingsManager
    public let kvsSyncService: KVSSyncService
    private var kvsSyncCancellables = Set<AnyCancellable>()
    private var lastSyncedAccentColor: String = AppAccentColor.blue.rawValue
    private var lastSyncedSwipeLayout: TrackSwipeLayout = .default
    private var lastSyncedPinsData: Data?
    private var syncBootstrapTask: Task<Void, Never>?
    private var firstConnectRetryTask: Task<Void, Never>?
    private var firstConnectRetryAttempt = 0
    private var lastKnownICloudAccountStatus: CKAccountStatus = .couldNotDetermine
    private static let firstConnectRetryDelays: [TimeInterval] = [5, 15, 30, 60]

    // MARK: - Network Infrastructure

    /// Single source of truth for per-server active endpoints.
    /// Shared by PlexAPIClient (writes on failover), ServerHealthChecker (writes on probe),
    /// and SyncCoordinator (subscribes to keep API clients in sync).
    public let connectionRegistry: ServerConnectionRegistry

    /// Manages WebSocket connections to Plex servers for real-time notifications.
    /// Start on foreground, stop on background.
    public let webSocketCoordinator: PlexWebSocketCoordinator

    /// Reactive track availability combining device connectivity, per-server health,
    /// and local download state. Used by UI surfaces for dimming/blocking unavailable tracks.
    public let trackAvailabilityResolver: TrackAvailabilityResolver

    // MARK: - Legacy (kept for add-account flow)

    public let authService: PlexAuthService

    // MARK: - Initialization

    private init() {
        // Core infrastructure
        keychain = KeychainService.shared
        coreDataStack = CoreDataStack.shared
        authService = PlexAuthService(keychain: keychain)

        // Network infrastructure — single source of truth for endpoint state
        let registry = ServerConnectionRegistry()
        connectionRegistry = registry

        // Repositories
        libraryRepository = LibraryRepository(coreDataStack: coreDataStack)
        playlistRepository = PlaylistRepository(coreDataStack: coreDataStack)
        hubRepository = HubRepository()
        moodRepository = MoodRepository(coreDataStack: coreDataStack)
        downloadManager = DownloadManager(coreDataStack: coreDataStack)
        offlineDownloadTargetRepository = OfflineDownloadTargetRepository(coreDataStack: coreDataStack)
        artworkDownloadManager = ArtworkDownloadManager(coreDataStack: coreDataStack)
        let pendingMutationRepo = PendingMutationRepository(coreDataStack: coreDataStack)

        // Multi-source management - initialize on main actor
        let keychainRef = keychain
        let libraryRef = libraryRepository
        let playlistRef = playlistRepository
        let downloadManagerRef = downloadManager
        let offlineTargetRepoRef = offlineDownloadTargetRepository
        let artworkDownloadRef = artworkDownloadManager

        let am = MainActor.assumeIsolated {
            AccountManager(keychain: keychainRef, connectionRegistry: registry)
        }
        accountManager = am
        accountDiscoveryService = PlexAccountDiscoveryService(keychain: keychainRef)

        // Network monitoring (must be created before SyncCoordinator)
        let nm = MainActor.assumeIsolated {
            NetworkMonitor()
        }
        networkMonitor = nm

        // Server health checking (must be created before SyncCoordinator)
        let shc = MainActor.assumeIsolated {
            ServerHealthChecker(accountManager: am, networkMonitor: nm, connectionRegistry: registry)
        }
        serverHealthChecker = shc

        syncCoordinator = MainActor.assumeIsolated {
            SyncCoordinator(
                accountManager: am,
                libraryRepository: libraryRef,
                playlistRepository: playlistRef,
                artworkDownloadManager: artworkDownloadRef,
                networkMonitor: nm,
                serverHealthChecker: shc,
                connectionRegistry: registry
            )
        }
        let syncCoordinatorRef = syncCoordinator

        // Read Plex client identifier for WebSocket headers
        let plexClientId = (try? keychain.get(KeychainKey.plexClientIdentifier)) ?? UUID().uuidString

        // WebSocket coordinator for real-time server notifications
        let wsc = MainActor.assumeIsolated {
            PlexWebSocketCoordinator(
                accountManager: am,
                connectionRegistry: registry,
                serverHealthChecker: shc,
                clientIdentifier: plexClientId
            )
        }
        webSocketCoordinator = wsc

        // Wire WebSocket events to SyncCoordinator
        MainActor.assumeIsolated {
            wsc.onLibraryUpdate = { [weak syncCoordinatorRef] sectionKey in
                await syncCoordinatorRef?.syncSectionIncremental(sectionKey: sectionKey)
            }
            wsc.onPlaylistUpdate = { [weak syncCoordinatorRef] serverKey in
                await syncCoordinatorRef?.syncServerPlaylistsIncremental(serverKey: serverKey)
            }
            wsc.onConnectionAvailabilityChanged = { [weak syncCoordinatorRef] hasActiveWebSocket in
                syncCoordinatorRef?.adjustTimersForWebSocket(hasActiveWebSocket: hasActiveWebSocket)
            }
            wsc.onServerOffline = { serverKey in
                // Parse serverKey and trigger health check
                let parts = serverKey.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                let accountId = String(parts[0])
                let serverId = String(parts[1])
                _ = await shc.checkServer(accountId: accountId, serverId: serverId)
            }
            wsc.onServerHealthy = { [weak shc] serverKey in
                // Reset health check TTL by updating state directly
                let parts = serverKey.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let shc else { return }
                let accountId = String(parts[0])
                let serverId = String(parts[1])
                let currentState = await MainActor.run {
                    shc.getServerState(accountId: accountId, serverId: serverId)
                }
                // If server was unknown/offline, run a health check to establish proper state
                if !currentState.isAvailable {
                    _ = await shc.checkServer(accountId: accountId, serverId: serverId)
                }
            }

        }

        // Track availability resolver — reactive per-server + per-download availability
        trackAvailabilityResolver = MainActor.assumeIsolated {
            TrackAvailabilityResolver(
                networkMonitor: nm,
                serverHealthChecker: shc,
                downloadManager: downloadManagerRef
            )
        }

        let offlineBackgroundCoordinatorRef = MainActor.assumeIsolated {
            OfflineBackgroundExecutionCoordinator()
        }
        offlineBackgroundExecutionCoordinator = offlineBackgroundCoordinatorRef

        // Toast center created early so OfflineDownloadService can reference it
        let toastCenterRef = MainActor.assumeIsolated { ToastCenter() }
        toastCenter = toastCenterRef

        // Lyrics service — fetching, parsing, and caching lyrics
        // Created before OfflineDownloadService so downloads can pre-cache lyrics
        let lyricsServiceRef = MainActor.assumeIsolated {
            LyricsService(syncCoordinator: syncCoordinatorRef)
        }
        lyricsService = lyricsServiceRef

        let offlineServiceRef = MainActor.assumeIsolated {
            OfflineDownloadService(
                downloadManager: downloadManagerRef,
                targetRepository: offlineTargetRepoRef,
                libraryRepository: libraryRef,
                playlistRepository: playlistRef,
                syncCoordinator: syncCoordinatorRef,
                networkMonitor: nm,
                backgroundExecutionCoordinator: offlineBackgroundCoordinatorRef,
                artworkDownloadManager: artworkDownloadRef,
                toastCenter: toastCenterRef,
                lyricsService: lyricsServiceRef
            )
        }
        offlineDownloadService = offlineServiceRef

        MainActor.assumeIsolated {
            syncCoordinatorRef.onPlaylistRefreshCompleted = { [weak offlineServiceRef] serverSourceKey in
                Task { @MainActor in
                    await offlineServiceRef?.handlePlaylistRefreshCompleted(serverSourceKey: serverSourceKey)
                }
            }

            syncCoordinatorRef.onFavoritesRatingChanged = { [weak offlineServiceRef] in
                await offlineServiceRef?.reconcileFavoritesTargetIfEnabled()
            }

            // When PMS download queue completes an item, restart the download
            // service queue so it picks up prepared downloads promptly.
            wsc.onDownloadQueueCompleted = { [weak offlineServiceRef] in
                await offlineServiceRef?.handleDownloadQueueCompleted()
            }
        }

        // Power state monitor — observes Low Power Mode for battery-aware behavior
        let powerMonitorRef = MainActor.assumeIsolated { PowerStateMonitor() }
        powerStateMonitor = powerMonitorRef

        // Persistent log service — real-time session file logging for TestFlight diagnostics.
        // Wires handlers for Core, API, and Persistence loggers. UI + App wired from EnsembleApp.
        let logServiceRef = MainActor.assumeIsolated { PersistentLogService() }
        persistentLogService = logServiceRef
        MainActor.assumeIsolated { logServiceRef.installHandlers() }

        // User profile store — local persistence for profile name + avatar
        let profileStoreRef = MainActor.assumeIsolated { UserProfileStore() }
        userProfileStore = profileStoreRef

        // Cloud sync service — CloudKit sync for profile data (and future sync targets)
        let cloudSyncRef = CloudSyncService()
        cloudSyncService = cloudSyncRef

        // Sync settings — per-device toggle control for iCloud sync features
        let syncSettingsRef = MainActor.assumeIsolated { SyncSettingsManager() }
        syncSettingsManager = syncSettingsRef

        // KVS sync service — NSUbiquitousKeyValueStore for settings, pins, library flags
        let kvsRef = MainActor.assumeIsolated { KVSSyncService() }
        kvsSyncService = kvsRef

        // Wire profile updates to CloudKit push
        MainActor.assumeIsolated {
            profileStoreRef.onProfileUpdated = { [weak profileStoreRef] profile in
                let imageData = profileStoreRef?.getProfileImageData()
                Task {
                    await cloudSyncRef.pushProfile(profile, imageData: imageData)
                    let transportState = await cloudSyncRef.currentProfileTransportState()
                    await MainActor.run {
                        syncSettingsRef.setProfileStatus(
                            phase: .transport(transportState),
                            direction: .pushedFromThisDevice,
                            detail: "Pushed profile changes from this device."
                        )
                    }
                }
            }
        }

        // Wire CloudKit remote changes to local profile store
        let profileStoreForCloud = profileStoreRef
        Task {
            await cloudSyncRef.setRemoteChangeHandler { [profileStoreForCloud] profile, imageData in
                await MainActor.run {
                    profileStoreForCloud.applyRemoteProfile(profile, imageData: imageData)
                    syncSettingsRef.setProfileStatus(
                        phase: .transport(.available),
                        direction: .pulledFromICloud,
                        detail: "Pulled profile changes from iCloud."
                    )
                }
            }

            await cloudSyncRef.subscribeToChanges()
        }

        // Pause/resume downloads when Low Power Mode is toggled
        let offlineServiceForPower = offlineServiceRef
        MainActor.assumeIsolated {
            var powerCancellable: AnyCancellable?
            let powerMonitor = powerMonitorRef
            powerCancellable = powerMonitor.$isLowPowerMode
                .dropFirst() // Skip initial value — only react to changes
                .sink { [weak offlineServiceForPower] isLowPower in
                    _ = powerCancellable // retain
                    Task { @MainActor in
                        await offlineServiceForPower?.setLowPowerModePaused(isLowPower)
                    }
                }
        }

        // Services using sync coordinator
        // Note: artworkLoader must be created before playbackService since it's a dependency
        let artworkLoaderRef = ArtworkLoader(syncCoordinator: syncCoordinator)
        artworkLoader = artworkLoaderRef

        // Wire artwork invalidation from WebSocket events to the artwork loader
        let artworkLoaderForWS = artworkLoaderRef
        MainActor.assumeIsolated {
            wsc.onArtworkInvalidation = { ratingKey, typeString in
                let type: ArtworkType
                switch typeString {
                case "album": type = .album
                case "artist": type = .artist
                default: type = .album
                }
                await artworkLoaderForWS.invalidateArtwork(ratingKey: ratingKey, type: type)
            }
        }
        
        // Pre-computed frequency analyzer (decoupled from audio pipeline)
        let audioAnalyzerRef = MainActor.assumeIsolated {
            FrequencyAnalysisService()
        }
        audioAnalyzer = audioAnalyzerRef

        let playbackServiceRef = PlaybackService(
            syncCoordinator: syncCoordinator,
            networkMonitor: nm,
            artworkLoader: artworkLoaderRef,
            audioAnalyzer: audioAnalyzerRef,
            downloadManager: downloadManagerRef
        )
        playbackService = playbackServiceRef
        siriPlaybackCoordinator = MainActor.assumeIsolated {
            SiriPlaybackCoordinator(
                accountManager: am,
                libraryRepository: libraryRef,
                playlistRepository: playlistRef,
                playbackService: playbackServiceRef
            )
        }

        // Wire playback observation so sidecar analysis prioritizes the playing track.
        // When a track with a local file starts playing and its sidecar doesn't exist yet,
        // it moves to the front of the analysis queue for fast visualizer readiness.
        MainActor.assumeIsolated {
            offlineServiceRef.observePlayback(
                trackPublisher: playbackServiceRef.currentTrackPublisher,
                playbackStatePublisher: playbackServiceRef.playbackStatePublisher
            )
            syncCoordinatorRef.shouldDeferForegroundHealthRefresh = { [weak offlineServiceRef] in
                offlineServiceRef?.shouldDeferForegroundHealthRefresh ?? false
            }
        }

        // Settings manager
        settingsManager = MainActor.assumeIsolated {
            SettingsManager()
        }

        let downloadRef = downloadManager

        // Navigation coordinator
        navigationCoordinator = MainActor.assumeIsolated {
            NavigationCoordinator()
        }
        
        // Hub order manager
        hubOrderManager = HubOrderManager()

        // Pin manager
        pinManager = MainActor.assumeIsolated {
            PinManager()
        }

        libraryVisibilityStore = MainActor.assumeIsolated {
            LibraryVisibilityStore()
        }

        siriMediaIndexStore = MainActor.assumeIsolated {
            SiriMediaIndexStore(
                libraryRepository: libraryRef,
                playlistRepository: playlistRef
            )
        }

        siriMediaUserContextManager = MainActor.assumeIsolated {
            SiriMediaUserContextManager(
                libraryRepository: libraryRef,
                playlistRepository: playlistRef
            )
        }

        // Cache manager - must be initialized after downloadManager and lyricsService
        cacheManager = MainActor.assumeIsolated {
            CacheManager(
                libraryRepository: libraryRef,
                artworkDownloadManager: artworkDownloadRef,
                downloadManager: downloadRef,
                lyricsService: lyricsServiceRef
            )
        }

        // Mutation coordinator — unified mutation routing with offline queue support
        let mutationCoordinatorRef = MainActor.assumeIsolated {
            MutationCoordinator(
                repository: pendingMutationRepo,
                networkMonitor: nm,
                syncCoordinator: syncCoordinatorRef
            )
        }
        mutationCoordinator = mutationCoordinatorRef

        metadataMutationService = MainActor.assumeIsolated {
            MetadataMutationService(
                libraryRepository: libraryRef,
                downloadManager: downloadManagerRef,
                targetRepository: offlineTargetRepoRef,
                artworkDownloadManager: artworkDownloadRef,
                isOffline: { syncCoordinatorRef.isOffline },
                canManageServer: { accountId, serverId in
                    am.plexAccounts
                        .first(where: { $0.id == accountId })?
                        .servers
                        .first(where: { $0.id == serverId })?
                        .owned ?? false
                },
                makeClient: { accountId, serverId in
                    am.makeAPIClient(accountId: accountId, serverId: serverId)
                },
                clearLyricsCache: { ratingKey, sourceCompositeKey in
                    lyricsServiceRef.clearCache(forTrackRatingKey: ratingKey, sourceCompositeKey: sourceCompositeKey)
                },
                removeDeletedTracksFromPlayback: { trackIDs in
                    playbackServiceRef.removeDeletedTracks(trackIDs)
                }
            )
        }

        siriAffinityCoordinator = MainActor.assumeIsolated {
            SiriAffinityCoordinator(
                playbackService: playbackServiceRef,
                mutationCoordinator: mutationCoordinatorRef,
                toastCenter: toastCenterRef
            )
        }

        siriAddToPlaylistCoordinator = MainActor.assumeIsolated {
            SiriAddToPlaylistCoordinator(
                playbackService: playbackServiceRef,
                mutationCoordinator: mutationCoordinatorRef,
                playlistRepository: playlistRef,
                toastCenter: toastCenterRef
            )
        }

        // Wire mutation coordinator into PlaybackService for offline lock-screen rating support
        MainActor.assumeIsolated {
            playbackServiceRef.setMutationCoordinator(mutationCoordinatorRef)
        }

        // Sync aurora visualization setting to frequency analyzer.
        // When disabled, the 30Hz display timer won't start — saves measurable CPU on A9.
        MainActor.assumeIsolated {
            audioAnalyzerRef.visualizationEnabled = UserDefaults.standard.bool(forKey: "auroraVisualizationEnabled")
        }

        // Sharing services — SongLinkService resolves universal links, ShareService coordinates payloads
        #if canImport(MusicKit)
        let songLinkRef = SongLinkService(searcher: MusicKitCatalogSearcher())
        #else
        // watchOS 8 fallback — MusicKit unavailable, links will fall back to plain text
        let songLinkRef = SongLinkService(searcher: NoOpMusicCatalogSearcher())
        #endif
        songLinkService = songLinkRef

        shareService = MainActor.assumeIsolated {
            ShareService(
                songLinkService: songLinkRef,
                syncCoordinator: syncCoordinatorRef,
                downloadManager: downloadManagerRef
            )
        }

        // Wire up artwork cache invalidation when server connections change.
        // Must be done after all properties are initialized.
        let syncRef = syncCoordinator
        MainActor.assumeIsolated {
            syncRef.onConnectionsRefreshed = { [weak artworkLoaderRef] in
                await artworkLoaderRef?.invalidateURLCache()
            }

            // When tracks are reparented (album changed), invalidate cached artwork
            // for the old album so ArtworkView re-fetches the correct cover
            syncRef.onTrackAlbumChanged = { [weak artworkLoaderRef] reparentedTracks in
                guard let artworkLoader = artworkLoaderRef else { return }
                for info in reparentedTracks {
                    // Invalidate old album artwork (stale cache entry)
                    await artworkLoader.invalidateArtwork(ratingKey: info.oldAlbumRatingKey, type: .album)
                    // Invalidate track-level artwork if it was cached under the track's own key
                    await artworkLoader.invalidateArtwork(ratingKey: info.trackRatingKey, type: .album)
                }
            }

            syncRef.onSourceCleanup = { [weak lyricsServiceRef] sourceKey in
                lyricsServiceRef?.clearCache(forSourceCompositeKey: sourceKey)
                // Remove download stubs and offline targets for the removed source
                try? await offlineTargetRepoRef.deleteTargets(forSourceCompositeKey: sourceKey)
                try? await downloadManagerRef.deleteDownloads(forSourceCompositeKey: sourceKey)
            }
        }

        // Wire KVS sync for settings, pins, and library flags with deferred bootstrap.
        MainActor.assumeIsolated {
            let settings = settingsManager
            let kvs = kvsRef
            let syncToggles = syncSettingsRef
            let pins = pinManager
            let acctMgr = accountManager
            let discovery = accountDiscoveryService

            kvsRef.onRemoteAccentColorChanged = { [weak self] colorName in
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

            kvsRef.onRemoteSwipeLayoutChanged = { [weak self] data in
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

                    guard syncToggles.isFeatureEnabled(.swipeActions) else { return }
                    let currentLayout = settings.trackSwipeLayout
                    guard currentLayout != self.lastSyncedSwipeLayout else { return }
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
                .store(in: &kvsSyncCancellables)

            kvsRef.onRemotePinsChanged = { [weak self, weak pins] data in
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

            acctMgr.onNewAccountsFromSync = { [weak acctMgr, weak syncToggles] newCredentials in
                guard let acctMgr, let syncToggles else { return }
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
                                if syncToggles.isFeatureEnabled(.libraries) {
                                    config = acctMgr.applyingSyncedLibraryFlags(to: config)
                                }
                                acctMgr.addPlexAccount(config)
                                acctMgr.setAwaitingCloudSources(false)
                                syncCoordinatorRef.refreshProviders()
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
                                        await syncCoordinatorRef.sync(sources: enabledSources)
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

            kvsRef.onRemoteLibraryFlagsChanged = { [weak acctMgr] data in
                guard let acctMgr else { return }
                guard syncToggles.isFeatureEnabled(.libraries) else { return }
                Task { @MainActor in
                    let result = acctMgr.applyLibraryFlags(data)
                    syncToggles.recordFeatureActivity(
                        for: .libraries,
                        state: .appliedRemote,
                        direction: .pulledFromICloud,
                        detail: "Pulled library selection from iCloud."
                    )

                    // Reconcile disabled sources on every remote library-flag payload,
                    // even when no flags changed this run. This prevents stale cached
                    // data from disabled libraries from leaking into browse surfaces.
                    let disabledSourcesToCleanup = Array(Set(result.disabledSources + acctMgr.disabledSources()))
                    if !disabledSourcesToCleanup.isEmpty {
                        await syncCoordinatorRef.cleanupRemovedSourcesIfPresent(disabledSourcesToCleanup)
                    }

                    if !acctMgr.hasAnySources && !syncToggles.hasCompletedFirstConnect {
                        self.scheduleSyncBootstrap(reason: "remote-library-flags", feature: .sources)
                    }

                    guard result.hasChanges else { return }

                    syncCoordinatorRef.refreshProviders()

                    for server in result.serversNeedingPlaylistCleanup {
                        await syncCoordinatorRef.cleanupServerPlaylists(
                            accountId: server.accountId,
                            serverId: server.serverId
                        )
                    }

                    if !result.enabledSources.isEmpty {
                        await syncCoordinatorRef.sync(sources: result.enabledSources)
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

            kvsRef.onInitialSyncCompleted = { [weak self, weak syncToggles] in
                guard let self, let syncToggles else { return }
                guard syncToggles.isMasterSyncEnabled, !syncToggles.hasCompletedFirstConnect else { return }
                self.scheduleSyncBootstrap(reason: "kvs-initial-sync")
            }

            syncSettingsRef.onMasterSyncEnabled = { [weak self] in
                self?.scheduleSyncBootstrap(reason: "master-enabled")
            }

            syncSettingsRef.onFeatureReEnabled = { [weak self] feature in
                self?.scheduleSyncBootstrap(reason: "feature-reenabled", feature: feature)
            }
        }

        MainActor.assumeIsolated {
            lastSyncedAccentColor = settingsManager.accentColorName
            lastSyncedSwipeLayout = settingsManager.trackSwipeLayout
            lastSyncedPinsData = pinManager.exportPinsData()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSyncState(reason: "launch")
        }
    }

    @MainActor
    public func reconcileSyncOnForeground() async {
        await refreshSyncState(reason: "foreground")
    }

    @MainActor
    public func runManualSync() async {
        syncSettingsManager.beginManualSync()
        defer { syncSettingsManager.finishManualSync() }
        await refreshSyncState(reason: "manual")
    }

    @MainActor
    private func refreshSyncState(
        reason: String,
        feature: SyncSettingsManager.SyncFeature? = nil
    ) async {
        if syncSettingsManager.isMasterSyncEnabled {
            lastKnownICloudAccountStatus = await cloudSyncService.currentAccountStatus()
            await performSyncBootstrap(reason: reason, feature: feature)
        }

        await reconcileProfileSync(reason: reason)
        scheduleFirstConnectRetryIfNeeded(reason: reason)
    }

    @MainActor
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
            guard !shouldKeepFirstConnectPending else {
                syncSettingsManager.setProfileStatus(
                    phase: .unknown,
                    direction: nil,
                    detail: "Waiting for iCloud profile during first-device sync."
                )
                return
            }

            syncSettingsManager.setProfileStatus(
                phase: .noRecord,
                direction: nil,
                detail: "No profile found in iCloud yet."
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

    @MainActor
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

    @MainActor
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
        case .error:
            return "Profile sync could not confirm iCloud status right now."
        }
    }

    @MainActor
    private func scheduleSyncBootstrap(reason: String, feature: SyncSettingsManager.SyncFeature? = nil) {
        syncBootstrapTask?.cancel()
        syncBootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSyncState(reason: reason, feature: feature)
        }
    }

    @MainActor
    private var shouldKeepFirstConnectPending: Bool {
        !syncSettingsManager.hasCompletedFirstConnect &&
        firstConnectRetryAttempt < Self.firstConnectRetryDelays.count
    }

    @MainActor
    private var needsFirstConnectRetry: Bool {
        guard shouldKeepFirstConnectPending else { return false }

        let waitingForSources =
            Self.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: syncSettingsManager.isFeatureEnabled(.sources),
                hasAnySources: accountManager.hasAnySources,
                hasSyncedCloudCredentials: accountManager.hasSyncedCloudCredentials(),
                accountStatus: lastKnownICloudAccountStatus
            )

        let waitingForProfile =
            userProfileStore.profile.isEmpty &&
            syncSettingsManager.profileStatus.phase == .unknown &&
            !Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus)

        return waitingForSources || waitingForProfile
    }

    @MainActor
    private func scheduleFirstConnectRetryIfNeeded(reason: String) {
        guard syncSettingsManager.isMasterSyncEnabled else {
            firstConnectRetryTask?.cancel()
            firstConnectRetryTask = nil
            firstConnectRetryAttempt = 0
            return
        }

        guard !syncSettingsManager.hasCompletedFirstConnect else {
            firstConnectRetryTask?.cancel()
            firstConnectRetryTask = nil
            firstConnectRetryAttempt = 0
            return
        }

        guard needsFirstConnectRetry else {
            firstConnectRetryTask?.cancel()
            firstConnectRetryTask = nil
            return
        }

        guard firstConnectRetryTask == nil else { return }
        let attemptNumber = firstConnectRetryAttempt + 1
        let delay = Self.firstConnectRetryDelays[firstConnectRetryAttempt]
        firstConnectRetryAttempt += 1

        EnsembleLogger.info(
            "Sync bootstrap: scheduling first-connect retry \(attemptNumber)/\(Self.firstConnectRetryDelays.count) in \(Int(delay))s after \(reason)"
        )

        firstConnectRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.firstConnectRetryTask = nil }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await self.refreshSyncState(reason: "first-connect-retry-\(attemptNumber)")
        }
    }

    @MainActor
    private func performSyncBootstrap(reason: String, feature: SyncSettingsManager.SyncFeature? = nil) async {
        guard syncSettingsManager.isMasterSyncEnabled else { return }

        let featuresToBootstrap: [SyncSettingsManager.SyncFeature]
        if let feature {
            featuresToBootstrap = [feature]
        } else {
            featuresToBootstrap = SyncSettingsManager.SyncFeature.allCases.filter {
                syncSettingsManager.isFeatureEnabled($0)
            }
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

    @MainActor
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

    @MainActor
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
        case .pins:
            return await bootstrapPins(reason: reason)
        case .sources:
            return bootstrapSources(reason: reason)
        case .libraries:
            return await bootstrapLibraryFlags(reason: reason)
        }
    }

    @MainActor
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
            if Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus) {
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

    @MainActor
    private func bootstrapAccentColor(reason: String) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.accentColor) else {
            syncSettingsManager.setFeatureState(.idle, for: .accentColor)
            return true
        }

        guard kvsSyncService.isAvailable else {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .accentColor)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .accentColor)
        kvsSyncService.synchronize()

        if let value = kvsSyncService.pullString(forKey: KVSSyncService.KVSKey.accentColor) {
            kvsSyncService.onRemoteAccentColorChanged?(value)
            return true
        }

        if Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus) {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .accentColor)
            return true
        }

        let didSettleInitialSync = await kvsSyncService.waitForInitialSync()
        if let value = kvsSyncService.pullString(forKey: KVSSyncService.KVSKey.accentColor) {
            kvsSyncService.onRemoteAccentColorChanged?(value)
            return true
        }

        guard didSettleInitialSync else {
            EnsembleLogger.info("Sync bootstrap: waiting for KVS accent color after \(reason)")
            syncSettingsManager.setFeatureState(.waitingForTransport, for: .accentColor)
            return false
        }

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

    @MainActor
    private func bootstrapSwipeActions(reason: String) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.swipeActions) else {
            syncSettingsManager.setFeatureState(.idle, for: .swipeActions)
            return true
        }

        guard kvsSyncService.isAvailable else {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .swipeActions)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .swipeActions)
        kvsSyncService.synchronize()

        if let data = kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.swipeLayout) {
            kvsSyncService.onRemoteSwipeLayoutChanged?(data)
            return true
        }

        if Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus) {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .swipeActions)
            return true
        }

        let didSettleInitialSync = await kvsSyncService.waitForInitialSync()
        if let data = kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.swipeLayout) {
            kvsSyncService.onRemoteSwipeLayoutChanged?(data)
            return true
        }

        guard didSettleInitialSync else {
            EnsembleLogger.info("Sync bootstrap: waiting for KVS swipe layout after \(reason)")
            syncSettingsManager.setFeatureState(.waitingForTransport, for: .swipeActions)
            return false
        }

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

    @MainActor
    private func bootstrapPins(reason: String) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.pins) else {
            syncSettingsManager.setFeatureState(.idle, for: .pins)
            return true
        }

        guard kvsSyncService.isAvailable else {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .pins)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .pins)
        kvsSyncService.synchronize()

        if let data = kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.pins) {
            kvsSyncService.onRemotePinsChanged?(data)
            return true
        }

        if Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus) {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .pins)
            return true
        }

        let didSettleInitialSync = await kvsSyncService.waitForInitialSync()
        if let data = kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.pins) {
            kvsSyncService.onRemotePinsChanged?(data)
            return true
        }

        guard didSettleInitialSync else {
            EnsembleLogger.info("Sync bootstrap: waiting for KVS pins after \(reason)")
            syncSettingsManager.setFeatureState(.waitingForTransport, for: .pins)
            return false
        }

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

    @MainActor
    private func bootstrapLibraryFlags(reason: String) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.libraries) else {
            syncSettingsManager.setFeatureState(.idle, for: .libraries)
            return true
        }

        guard kvsSyncService.isAvailable else {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .libraries)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .libraries)
        kvsSyncService.synchronize()

        if let data = kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.libraryFlags) {
            kvsSyncService.onRemoteLibraryFlagsChanged?(data)
            return true
        }

        if Self.isBootstrapTransportUnavailable(accountStatus: lastKnownICloudAccountStatus) {
            syncSettingsManager.setFeatureState(.transportUnavailable, for: .libraries)
            return true
        }

        let didSettleInitialSync = await kvsSyncService.waitForInitialSync()
        if let data = kvsSyncService.pullData(forKey: KVSSyncService.KVSKey.libraryFlags) {
            kvsSyncService.onRemoteLibraryFlagsChanged?(data)
            return true
        }

        guard didSettleInitialSync else {
            EnsembleLogger.info("Sync bootstrap: waiting for KVS library flags after \(reason)")
            syncSettingsManager.setFeatureState(.waitingForTransport, for: .libraries)
            return false
        }

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

    static func isBootstrapTransportUnavailable(accountStatus: CKAccountStatus) -> Bool {
        switch accountStatus {
        case .noAccount, .restricted:
            return true
        default:
            return false
        }
    }

    static func shouldRetryFirstConnectForSources(
        sourcesFeatureEnabled: Bool,
        hasAnySources: Bool,
        hasSyncedCloudCredentials: Bool,
        accountStatus: CKAccountStatus
    ) -> Bool {
        sourcesFeatureEnabled &&
        !hasAnySources &&
        !hasSyncedCloudCredentials &&
        !isBootstrapTransportUnavailable(accountStatus: accountStatus)
    }

    // MARK: - Shared ViewModel State

    /// The active NowPlayingViewModel from the main UI.
    /// Set by MainTabView/SidebarView so the external display SceneDelegate
    /// can observe the same instance for AirPlay screen mirroring.
    @MainActor public var activeNowPlayingViewModel: NowPlayingViewModel?

    @MainActor
    public func persistPlaybackStateSnapshot() {
        playbackService.persistPlaybackStateSnapshot()
    }

    // MARK: - View Model Factories

    @MainActor
    public func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            accountManager: accountManager,
            visibilityStore: libraryVisibilityStore,
            toastCenter: toastCenter
        )
    }

    @MainActor
    public func makeNowPlayingViewModel() -> NowPlayingViewModel {
        NowPlayingViewModel(
            playbackService: playbackService,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            navigationCoordinator: navigationCoordinator,
            toastCenter: toastCenter,
            mutationCoordinator: mutationCoordinator,
            trackAvailabilityResolver: trackAvailabilityResolver,
            lyricsService: lyricsService
        )
    }

    @MainActor
    public func makeArtistDetailViewModel(artist: Artist) -> ArtistDetailViewModel {
        ArtistDetailViewModel(
            artist: artist,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator
        )
    }

    @MainActor
    public func makeAlbumDetailViewModel(album: Album) -> AlbumDetailViewModel {
        AlbumDetailViewModel(
            album: album,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator
        )
    }

    @MainActor
    public func makePlaylistViewModel() -> PlaylistViewModel {
        PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator,
            toastCenter: toastCenter
        )
    }

    @MainActor
    public func makePlaylistDetailViewModel(playlist: Playlist) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepository,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator
        )
    }

    @MainActor
    public func makeMergedPlaylistDetailViewModel(displayPlaylist: DisplayPlaylist) -> MergedPlaylistDetailViewModel {
        MergedPlaylistDetailViewModel(
            displayPlaylist: displayPlaylist,
            playlistRepository: playlistRepository,
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator
        )
    }

    @MainActor
    public func makeSearchViewModel() -> SearchViewModel {
        SearchViewModel(
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            hubRepository: hubRepository,
            moodRepository: moodRepository,
            accountManager: accountManager,
            visibilityStore: libraryVisibilityStore
        )
    }

    @MainActor
    public func makeDownloadsViewModel() -> DownloadsViewModel {
        DownloadsViewModel(
            offlineDownloadService: offlineDownloadService,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            mutationCoordinator: mutationCoordinator,
            accountManager: accountManager,
            downloadManager: downloadManager
        )
    }

    @MainActor
    public func makeLibraryDownloadDetailViewModel(
        sourceCompositeKey: String,
        title: String
    ) -> LibraryDownloadDetailViewModel {
        LibraryDownloadDetailViewModel(
            sourceCompositeKey: sourceCompositeKey,
            title: title,
            downloadManager: downloadManager,
            libraryRepository: libraryRepository,
            offlineDownloadService: offlineDownloadService
        )
    }

    @MainActor
    public func makeDownloadManagerSettingsViewModel() -> DownloadManagerSettingsViewModel {
        DownloadManagerSettingsViewModel(
            offlineDownloadService: offlineDownloadService,
            targetRepository: offlineDownloadTargetRepository,
            downloadManager: downloadManager
        )
    }

    @MainActor
    public func makeDownloadTargetDetailViewModel(summary: DownloadedItemSummary) -> DownloadTargetDetailViewModel {
        DownloadTargetDetailViewModel(
            summary: summary,
            offlineDownloadTargetRepository: offlineDownloadTargetRepository,
            downloadManager: downloadManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            offlineDownloadService: offlineDownloadService
        )
    }

    @MainActor
    public func makeOfflineServersViewModel() -> OfflineServersViewModel {
        OfflineServersViewModel(
            accountManager: accountManager,
            offlineDownloadService: offlineDownloadService
        )
    }

    @MainActor
    public func makeAddPlexAccountViewModel() -> AddPlexAccountViewModel {
        AddPlexAccountViewModel(
            authService: authService,
            accountDiscoveryService: accountDiscoveryService,
            accountManager: accountManager,
            syncCoordinator: syncCoordinator
        )
    }

    @MainActor
    public func makeMusicSourceAccountDetailViewModel(accountId: String) -> MusicSourceAccountDetailViewModel {
        MusicSourceAccountDetailViewModel(
            accountId: accountId,
            accountManager: accountManager,
            accountDiscoveryService: accountDiscoveryService,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator,
            webSocketCoordinator: webSocketCoordinator
        )
    }

    @MainActor
    public func makeFavoritesViewModel() -> FavoritesViewModel {
        FavoritesViewModel(libraryRepository: libraryRepository)
    }
    
    @MainActor
    public func makePinnedViewModel() -> PinnedViewModel {
        PinnedViewModel(
            pinManager: pinManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )
    }

    @MainActor
    public func makePendingMutationsViewModel() -> PendingMutationsViewModel {
        PendingMutationsViewModel(
            mutationCoordinator: mutationCoordinator,
            repository: PendingMutationRepository(coreDataStack: coreDataStack),
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )
    }

    @MainActor
    public func makeHomeViewModel() -> HomeViewModel {
        HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            hubRepository: hubRepository,
            hubOrderManager: hubOrderManager,
            visibilityStore: libraryVisibilityStore
        )
    }
}

// MARK: - Environment Key

import SwiftUI

private struct DependencyContainerKey: EnvironmentKey {
    static let defaultValue = DependencyContainer.shared
}

public extension EnvironmentValues {
    var dependencies: DependencyContainer {
        get { self[DependencyContainerKey.self] }
        set { self[DependencyContainerKey.self] = newValue }
    }
}
