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
                }
            }
        }

        // Wire CloudKit remote changes to local profile store
        Task {
            await cloudSyncRef.setRemoteChangeHandler { [weak profileStoreRef] profile, imageData in
                await MainActor.run {
                    profileStoreRef?.applyRemoteProfile(profile, imageData: imageData)
                }
            }

            // Initial pull from CloudKit + subscribe to future changes
            if let remote = await cloudSyncRef.pullProfile() {
                await MainActor.run {
                    profileStoreRef.applyRemoteProfile(remote.profile, imageData: remote.imageData)
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

        // Wire KVS sync for accent color + swipe layout
        MainActor.assumeIsolated {
            let settings = settingsManager
            let kvs = kvsRef
            let syncToggles = syncSettingsRef

            // Push accent color on local change
            kvsRef.onRemoteAccentColorChanged = { colorName in
                guard syncToggles.isFeatureEnabled(.accentColor) else { return }
                settings.setAccentColor(AppAccentColor(rawValue: colorName) ?? .blue)
            }

            // Push swipe layout on remote change
            kvsRef.onRemoteSwipeLayoutChanged = { data in
                guard syncToggles.isFeatureEnabled(.swipeActions) else { return }
                if let layout = try? JSONDecoder().decode(TrackSwipeLayout.self, from: data) {
                    settings.trackSwipeLayout = layout
                }
            }

            // Observe local accent color changes → push to KVS
            settings.objectWillChange
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak settings, weak kvs, weak syncToggles] _ in
                    guard let settings = settings, let kvs = kvs, let syncToggles = syncToggles else { return }
                    guard syncToggles.isFeatureEnabled(.accentColor) else { return }
                    kvs.pushString(settings.accentColorName, forKey: KVSSyncService.KVSKey.accentColor)

                    guard syncToggles.isFeatureEnabled(.swipeActions) else { return }
                    if let data = try? JSONEncoder().encode(settings.trackSwipeLayout) {
                        kvs.pushData(data, forKey: KVSSyncService.KVSKey.swipeLayout)
                    }
                }
                .store(in: &kvsSyncCancellables)

            // Initial push of current values to KVS (if sync is on)
            if syncToggles.isFeatureEnabled(.accentColor) {
                kvs.pushString(settings.accentColorName, forKey: KVSSyncService.KVSKey.accentColor)
            }
            if syncToggles.isFeatureEnabled(.swipeActions),
               let data = try? JSONEncoder().encode(settings.trackSwipeLayout) {
                kvs.pushData(data, forKey: KVSSyncService.KVSKey.swipeLayout)
            }

            // Wire pins sync
            let pins = pinManager
            kvsRef.onRemotePinsChanged = { [weak pins] data in
                guard syncToggles.isFeatureEnabled(.pins), let pins = pins else { return }
                if let remotePins = try? JSONDecoder().decode([PinnedItem].self, from: data) {
                    pins.applyRemotePins(remotePins)
                }
            }

            // Push pins when they change locally
            pins.objectWillChange
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak pins, weak kvs, weak syncToggles] _ in
                    guard let pins = pins, let kvs = kvs, let syncToggles = syncToggles else { return }
                    guard syncToggles.isFeatureEnabled(.pins) else { return }
                    if let data = pins.exportPinsData() {
                        kvs.pushData(data, forKey: KVSSyncService.KVSKey.pins)
                    }
                }
                .store(in: &kvsSyncCancellables)

            // Initial push of pins
            if syncToggles.isFeatureEnabled(.pins), let data = pins.exportPinsData() {
                kvs.pushData(data, forKey: KVSSyncService.KVSKey.pins)
            }

            // Wire source credential sync reconciliation
            let acctMgr = accountManager
            let discovery = accountDiscoveryService
            acctMgr.onNewAccountsFromSync = { [weak acctMgr, weak syncToggles] newCredentials in
                guard let acctMgr = acctMgr, let syncToggles = syncToggles else { return }
                guard syncToggles.isFeatureEnabled(.sources) else { return }

                // Discover connections for each new synced account
                for credential in newCredentials {
                    Task {
                        do {
                            let result = try await discovery.discoverAccount(authToken: credential.authToken)
                            await MainActor.run {
                                let config = PlexAccountConfig(
                                    id: credential.accountId,
                                    email: credential.email,
                                    plexUsername: credential.plexUsername,
                                    displayTitle: credential.displayTitle,
                                    authToken: credential.authToken,
                                    servers: result.servers
                                )
                                acctMgr.addPlexAccount(config)
                                EnsembleLogger.info("Sync: discovered account \(credential.accountId) with \(result.servers.count) servers")
                            }
                        } catch {
                            EnsembleLogger.error("Sync: failed to discover account \(credential.accountId): \(error)")
                        }
                    }
                }
            }

            // Check for synced credentials on launch
            if syncToggles.isFeatureEnabled(.sources) {
                let newAccounts = acctMgr.pullSyncCredentials()
                if !newAccounts.isEmpty {
                    acctMgr.onNewAccountsFromSync?(newAccounts)
                }
            }

            // Wire library flags sync via KVS
            kvsRef.onRemoteLibraryFlagsChanged = { [weak acctMgr] data in
                guard syncToggles.isFeatureEnabled(.libraries), let acctMgr = acctMgr else { return }
                acctMgr.applyLibraryFlags(data)
            }

            // Push library flags when accounts change
            acctMgr.objectWillChange
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak acctMgr, weak kvs, weak syncToggles] _ in
                    guard let acctMgr = acctMgr, let kvs = kvs, let syncToggles = syncToggles else { return }
                    guard syncToggles.isFeatureEnabled(.libraries) else { return }
                    if let data = acctMgr.exportLibraryFlags() {
                        kvs.pushData(data, forKey: KVSSyncService.KVSKey.libraryFlags)
                    }
                }
                .store(in: &kvsSyncCancellables)

            // Initial push of library flags
            if syncToggles.isFeatureEnabled(.libraries), let data = acctMgr.exportLibraryFlags() {
                kvs.pushData(data, forKey: KVSSyncService.KVSKey.libraryFlags)
            }
        }
    }

    // MARK: - Shared ViewModel State

    /// The active NowPlayingViewModel from the main UI.
    /// Set by MainTabView/SidebarView so the external display SceneDelegate
    /// can observe the same instance for AirPlay screen mirroring.
    @MainActor public var activeNowPlayingViewModel: NowPlayingViewModel?

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
