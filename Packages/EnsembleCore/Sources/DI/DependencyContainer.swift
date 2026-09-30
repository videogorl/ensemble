import EnsembleAPI
import EnsembleDomain
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
    public let syncCursorRepository: SyncCursorRepositoryProtocol
    public let hubRepository: HubRepositoryProtocol
    public let moodRepository: MoodRepository
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
    public let sourceCacheCleanupService: SourceCacheCleaning
    public let homeHubLoader: HomeHubLoaderProtocol
    public let backgroundRefreshCoordinator: BackgroundRefreshCoordinator
    public let navigationCoordinator: NavigationCoordinator
    public let ensemblePermalinkResolver: EnsemblePermalinkResolver
    public let appReadinessCoordinator: AppReadinessCoordinator
    public let foregroundWorkScheduler: ForegroundWorkScheduler
    public let hubOrderManager: HubOrderManager
    public let pinManager: PinManager
    public let hiddenMediaStore: HiddenMediaStore
    public let pinMutationWorkflow: PinMutationWorkflow
    public let toastCenter: ToastCenter
    public let libraryVisibilityStore: LibraryVisibilityStore
    public let siriMediaIndexStore: SiriMediaIndexStore
    public let siriPlaybackCoordinator: SiriPlaybackCoordinator
    public let siriAffinityCoordinator: SiriAffinityCoordinator
    public let siriAddToPlaylistCoordinator: SiriAddToPlaylistCoordinator
    public let siriMediaUserContextManager: SiriMediaUserContextManager
    public let systemMediaIntegrationService: SystemMediaIntegrationService
    public let offlineBackgroundExecutionCoordinator: OfflineDownloadBackgroundCoordinating
    public let offlineDownloadService: OfflineDownloadService
    public let downloadMutationWorkflow: DownloadMutationWorkflow
    public let lyricsService: LyricsService
    public let mutationCoordinator: MutationCoordinator
    public let playlistMutationWorkflow: PlaylistMutationWorkflow
    public let trackRatingMutationWorkflow: TrackRatingMutationWorkflow
    public let collectionFavoriteMutationWorkflow: CollectionFavoriteMutationWorkflow
    public let metadataMutationService: MetadataMutationService
    public let metadataMutationWorkflow: MetadataMutationWorkflow
    public let songLinkService: SongLinkService
    public let shareService: ShareService
    public let powerStateMonitor: PowerStateMonitor
    public let persistentLogService: PersistentLogService
    internal let appBootstrapDiagnostics: AppBootstrapDiagnostics
    @MainActor internal var activeNowPlayingViewModelStorage: NowPlayingViewModel?

    // MARK: - Profile & Cloud Sync

    public let userProfileStore: UserProfileStore
    public let cloudSyncService: CloudSyncService
    public let syncSettingsManager: SyncSettingsManager
    public let kvsSyncService: KVSSyncService
    private let cloudSyncCoordinator: CloudSyncCoordinator
    private var hasScheduledDeferredSyncStartup = false

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

    private struct CoreBootstrap {
        let keychain: KeychainServiceProtocol
        let coreDataStack: CoreDataStack
        let authService: PlexAuthService
        let libraryRepository: LibraryRepositoryProtocol
        let playlistRepository: PlaylistRepositoryProtocol
        let syncCursorRepository: SyncCursorRepositoryProtocol
        let hubRepository: HubRepositoryProtocol
        let moodRepository: MoodRepository
        let downloadManager: DownloadManagerProtocol
        let offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol
        let artworkDownloadManager: ArtworkDownloadManagerProtocol
        let pendingMutationRepository: PendingMutationRepository
        let settingsManager: SettingsManager
        let navigationCoordinator: NavigationCoordinator
        let hubOrderManager: HubOrderManager
        let pinManager: PinManager
        let hiddenMediaStore: HiddenMediaStore
        let pinMutationWorkflow: PinMutationWorkflow
        let toastCenter: ToastCenter
        let libraryVisibilityStore: LibraryVisibilityStore
        let powerStateMonitor: PowerStateMonitor
        let persistentLogService: PersistentLogService
        let userProfileStore: UserProfileStore
        let cloudSyncService: CloudSyncService
        let syncSettingsManager: SyncSettingsManager
        let kvsSyncService: KVSSyncService
    }

    private struct NetworkBootstrap {
        let connectionRegistry: ServerConnectionRegistry
        let accountManager: AccountManager
        let accountDiscoveryService: PlexAccountDiscoveryService
        let networkMonitor: NetworkMonitor
        let serverHealthChecker: ServerHealthChecker
        let webSocketCoordinator: PlexWebSocketCoordinator
        let trackAvailabilityResolver: TrackAvailabilityResolver
    }

    private struct SyncBootstrap {
        let syncCoordinator: SyncCoordinator
    }

    private struct PlaybackBootstrap {
        let lyricsService: LyricsService
        let artworkLoader: ArtworkLoaderProtocol
        let audioAnalyzer: AudioAnalyzerProtocol
        let playbackService: PlaybackService
        let cacheManager: CacheManager
        let songLinkService: SongLinkService
        let shareService: ShareService
    }

    private struct MutationBootstrap {
        let offlineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinator
        let offlineDownloadService: OfflineDownloadService
        let downloadMutationWorkflow: DownloadMutationWorkflow
        let mutationCoordinator: MutationCoordinator
        let playlistMutationWorkflow: PlaylistMutationWorkflow
        let trackRatingMutationWorkflow: TrackRatingMutationWorkflow
        let collectionFavoriteMutationWorkflow: CollectionFavoriteMutationWorkflow
        let metadataMutationService: MetadataMutationService
        let metadataMutationWorkflow: MetadataMutationWorkflow
    }

    private struct SiriBootstrap {
        let siriMediaIndexStore: SiriMediaIndexStore
        let siriPlaybackCoordinator: SiriPlaybackCoordinator
        let siriAffinityCoordinator: SiriAffinityCoordinator
        let siriAddToPlaylistCoordinator: SiriAddToPlaylistCoordinator
        let siriMediaUserContextManager: SiriMediaUserContextManager
        let systemMediaIntegrationService: SystemMediaIntegrationService
    }

    private init() {
        let core = Self.buildCoreBootstrap()
        let network = Self.buildNetworkBootstrap(core: core)
        let sync = Self.buildSyncBootstrap(core: core, network: network)
        let builtForegroundWorkScheduler = MainActor.assumeIsolated {
            ForegroundWorkScheduler(thermalState: { core.powerStateMonitor.thermalState })
        }
        let builtAppReadinessCoordinator = MainActor.assumeIsolated {
            AppReadinessCoordinator(
                accountManager: network.accountManager,
                syncCoordinator: sync.syncCoordinator
            )
        }
        let playback = Self.buildPlaybackBootstrap(
            core: core,
            network: network,
            sync: sync,
            foregroundWorkScheduler: builtForegroundWorkScheduler
        )
        let mutation = Self.buildMutationBootstrap(
            core: core,
            network: network,
            sync: sync,
            playback: playback,
            foregroundWorkScheduler: builtForegroundWorkScheduler
        )
        let siri = Self.buildSiriBootstrap(
            core: core,
            network: network,
            playback: playback,
            mutation: mutation,
            foregroundWorkScheduler: builtForegroundWorkScheduler
        )

        keychain = core.keychain
        coreDataStack = core.coreDataStack
        authService = core.authService
        libraryRepository = core.libraryRepository
        playlistRepository = core.playlistRepository
        syncCursorRepository = core.syncCursorRepository
        hubRepository = core.hubRepository
        moodRepository = core.moodRepository
        downloadManager = core.downloadManager
        offlineDownloadTargetRepository = core.offlineDownloadTargetRepository
        artworkDownloadManager = core.artworkDownloadManager
        settingsManager = core.settingsManager
        navigationCoordinator = core.navigationCoordinator
        ensemblePermalinkResolver = MainActor.assumeIsolated {
            EnsemblePermalinkResolver(
                accountManager: network.accountManager,
                settingsManager: core.settingsManager,
                visibilityStore: core.libraryVisibilityStore,
                libraryRepository: core.libraryRepository,
                playlistRepository: core.playlistRepository
            )
        }
        appReadinessCoordinator = builtAppReadinessCoordinator
        foregroundWorkScheduler = builtForegroundWorkScheduler
        hubOrderManager = core.hubOrderManager
        pinManager = core.pinManager
        hiddenMediaStore = core.hiddenMediaStore
        pinMutationWorkflow = core.pinMutationWorkflow
        toastCenter = core.toastCenter
        libraryVisibilityStore = core.libraryVisibilityStore
        powerStateMonitor = core.powerStateMonitor
        persistentLogService = core.persistentLogService
        userProfileStore = core.userProfileStore
        cloudSyncService = core.cloudSyncService
        syncSettingsManager = core.syncSettingsManager
        kvsSyncService = core.kvsSyncService

        connectionRegistry = network.connectionRegistry
        accountManager = network.accountManager
        accountDiscoveryService = network.accountDiscoveryService
        networkMonitor = network.networkMonitor
        serverHealthChecker = network.serverHealthChecker
        webSocketCoordinator = network.webSocketCoordinator
        trackAvailabilityResolver = network.trackAvailabilityResolver

        syncCoordinator = sync.syncCoordinator

        lyricsService = playback.lyricsService
        artworkLoader = playback.artworkLoader
        audioAnalyzer = playback.audioAnalyzer
        playbackService = playback.playbackService
        cacheManager = playback.cacheManager
        songLinkService = playback.songLinkService
        shareService = playback.shareService
        let builtSourceCacheCleanupService = SourceCacheCleanupService(
            libraryRepository: libraryRepository,
            hubRepository: hubRepository,
            downloadManager: downloadManager,
            targetRepository: offlineDownloadTargetRepository,
            pendingMutationRepository: core.pendingMutationRepository,
            artworkDownloadManager: artworkDownloadManager,
            fetchArtworkRatingKeys: { [libraryRepository = core.libraryRepository] sourceKey in
                guard let repository = libraryRepository as? LibraryRepository else { return [] }
                return try await repository.fetchArtworkRatingKeys(forSourceCompositeKey: sourceKey)
            },
            countLibraryItemsForSource: { [libraryRepository = core.libraryRepository] sourceKey in
                guard let repository = libraryRepository as? LibraryRepository else { return 0 }
                return try await repository.countLibraryItems(forSourceCompositeKey: sourceKey)
            },
            countAllLibraryItems: { [libraryRepository = core.libraryRepository] in
                guard let repository = libraryRepository as? LibraryRepository else { return 0 }
                return try await repository.countAllLibraryItems()
            },
            countTargetsForSource: { [targetRepository = core.offlineDownloadTargetRepository] sourceKey in
                guard let repository = targetRepository as? OfflineDownloadTargetRepository else { return 0 }
                return try await repository.countTargets(forSourceCompositeKey: sourceKey)
            },
            countAllTargets: { [targetRepository = core.offlineDownloadTargetRepository] in
                guard let repository = targetRepository as? OfflineDownloadTargetRepository else { return 0 }
                return try await repository.countAllTargets()
            },
            countArtworkItems: { [artworkDownloadManager = core.artworkDownloadManager] in
                guard let manager = artworkDownloadManager as? ArtworkDownloadManager else { return 0 }
                return try await manager.getArtworkCacheFileCount()
            },
            clearLyricsCache: { [lyricsService = playback.lyricsService] sourceKey in
                await lyricsService.clearCache(forSourceCompositeKey: sourceKey)
            },
            clearAllLyricsCaches: { [lyricsService = playback.lyricsService] in
                await lyricsService.clearAllCaches()
            },
            clearSharedArtworkCaches: { [weak artworkLoader = playback.artworkLoader as? ArtworkLoader] in
                try await artworkLoader?.resetTransientCaches()
            }
        )
        sourceCacheCleanupService = builtSourceCacheCleanupService
        MainActor.assumeIsolated {
            playback.cacheManager.sourceCacheCleanupService = builtSourceCacheCleanupService
        }
        let builtHomeHubLoader = HomeHubLoader(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            hubRepository: hubRepository,
            hubOrderManager: hubOrderManager
        )
        homeHubLoader = builtHomeHubLoader

        offlineBackgroundExecutionCoordinator = mutation.offlineBackgroundExecutionCoordinator
        offlineDownloadService = mutation.offlineDownloadService
        builtSourceCacheCleanupService.onDownloadsRemoved = { [weak service = mutation.offlineDownloadService] in
            await service?.reconcileNativeTransfers()
        }
        MainActor.assumeIsolated {
            playback.cacheManager.onDownloadsRemoved = { [weak service = mutation.offlineDownloadService] in
                await service?.reconcileNativeTransfers()
            }
        }
        downloadMutationWorkflow = mutation.downloadMutationWorkflow
        mutationCoordinator = mutation.mutationCoordinator
        playlistMutationWorkflow = mutation.playlistMutationWorkflow
        trackRatingMutationWorkflow = mutation.trackRatingMutationWorkflow
        collectionFavoriteMutationWorkflow = mutation.collectionFavoriteMutationWorkflow
        metadataMutationService = mutation.metadataMutationService
        metadataMutationWorkflow = mutation.metadataMutationWorkflow

        siriMediaIndexStore = siri.siriMediaIndexStore
        siriPlaybackCoordinator = siri.siriPlaybackCoordinator
        siriAffinityCoordinator = siri.siriAffinityCoordinator
        siriAddToPlaylistCoordinator = siri.siriAddToPlaylistCoordinator
        siriMediaUserContextManager = siri.siriMediaUserContextManager
        systemMediaIntegrationService = siri.systemMediaIntegrationService
        playbackService.setSystemMediaIntegrationService(systemMediaIntegrationService)
        backgroundRefreshCoordinator = BackgroundRefreshCoordinator(
            syncCoordinator: sync.syncCoordinator,
            homeHubLoader: builtHomeHubLoader,
            siriMediaIndexStore: siri.siriMediaIndexStore,
            siriMediaUserContextManager: siri.siriMediaUserContextManager,
            systemMediaIntegrationService: siri.systemMediaIntegrationService
        )
        appBootstrapDiagnostics = Self.buildAppBootstrapDiagnostics(
            network: network,
            sync: sync,
            playback: playback,
            mutation: mutation
        )

        cloudSyncCoordinator = MainActor.assumeIsolated {
            CloudSyncCoordinator(
                userProfileStore: core.userProfileStore,
                cloudSyncService: core.cloudSyncService,
                syncSettingsManager: core.syncSettingsManager,
                kvsSyncService: core.kvsSyncService,
                settingsManager: core.settingsManager,
                pinManager: core.pinManager,
                hiddenMediaStore: core.hiddenMediaStore,
                accountManager: network.accountManager,
                accountDiscoveryService: network.accountDiscoveryService,
                syncCoordinator: sync.syncCoordinator
            )
        }

        wireCrossSubsystemCallbacks()

        MainActor.assumeIsolated {
            scheduleDeferredSyncStartup()
        }
        Task { @MainActor [weak builtForegroundWorkScheduler] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            builtForegroundWorkScheduler?.clearLaunchState()
        }
    }

    // MARK: - Bootstrap Builders

    private static func buildCoreBootstrap() -> CoreBootstrap {
        let keychain = KeychainService.shared
        let coreDataStack = CoreDataStack.shared
        let pinManager = MainActor.assumeIsolated { PinManager() }
        let artworkDownloadManager = ArtworkDownloadManager()
        Task.detached(priority: .utility) {
            artworkDownloadManager.preparePersistentCache()
        }

        return CoreBootstrap(
            keychain: keychain,
            coreDataStack: coreDataStack,
            authService: PlexAuthService(keychain: keychain),
            libraryRepository: LibraryRepository(coreDataStack: coreDataStack),
            playlistRepository: PlaylistRepository(coreDataStack: coreDataStack),
            syncCursorRepository: SyncCursorRepository(coreDataStack: coreDataStack),
            hubRepository: HubRepository(),
            moodRepository: MoodRepository(coreDataStack: coreDataStack),
            downloadManager: DownloadManager(coreDataStack: coreDataStack),
            offlineDownloadTargetRepository: OfflineDownloadTargetRepository(coreDataStack: coreDataStack),
            artworkDownloadManager: artworkDownloadManager,
            pendingMutationRepository: PendingMutationRepository(coreDataStack: coreDataStack),
            settingsManager: MainActor.assumeIsolated { SettingsManager() },
            navigationCoordinator: MainActor.assumeIsolated { NavigationCoordinator() },
            hubOrderManager: HubOrderManager(),
            pinManager: pinManager,
            hiddenMediaStore: MainActor.assumeIsolated { .shared },
            pinMutationWorkflow: MainActor.assumeIsolated { PinMutationWorkflow(pinManager: pinManager) },
            toastCenter: MainActor.assumeIsolated { ToastCenter() },
            libraryVisibilityStore: MainActor.assumeIsolated { LibraryVisibilityStore() },
            powerStateMonitor: MainActor.assumeIsolated { PowerStateMonitor() },
            persistentLogService: MainActor.assumeIsolated { PersistentLogService() },
            userProfileStore: MainActor.assumeIsolated { UserProfileStore() },
            cloudSyncService: CloudSyncService(),
            syncSettingsManager: MainActor.assumeIsolated { SyncSettingsManager() },
            kvsSyncService: MainActor.assumeIsolated { KVSSyncService() }
        )
    }

    private static func buildNetworkBootstrap(core: CoreBootstrap) -> NetworkBootstrap {
        let connectionRegistry = ServerConnectionRegistry()
        let networkMonitor = MainActor.assumeIsolated { NetworkMonitor() }
        let accountManager = MainActor.assumeIsolated {
            AccountManager(
                keychain: core.keychain,
                connectionRegistry: connectionRegistry,
                isNetworkAvailable: {
                    await MainActor.run {
                        networkMonitor.networkState.isConnected
                    }
                }
            )
        }
        let accountDiscoveryService = PlexAccountDiscoveryService(keychain: core.keychain)
        let serverHealthChecker = MainActor.assumeIsolated {
            ServerHealthChecker(
                accountManager: accountManager,
                networkMonitor: networkMonitor,
                connectionRegistry: connectionRegistry
            )
        }

        let plexClientId = PlexAuthService.storedClientIdentifier()
        let webSocketCoordinator = MainActor.assumeIsolated {
            PlexWebSocketCoordinator(
                accountManager: accountManager,
                connectionRegistry: connectionRegistry,
                networkMonitor: networkMonitor,
                clientIdentifier: plexClientId
            )
        }

        let trackAvailabilityResolver = MainActor.assumeIsolated {
            TrackAvailabilityResolver(
                networkMonitor: networkMonitor,
                serverHealthChecker: serverHealthChecker
            )
        }

        return NetworkBootstrap(
            connectionRegistry: connectionRegistry,
            accountManager: accountManager,
            accountDiscoveryService: accountDiscoveryService,
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker,
            webSocketCoordinator: webSocketCoordinator,
            trackAvailabilityResolver: trackAvailabilityResolver
        )
    }

    private static func buildSyncBootstrap(
        core: CoreBootstrap,
        network: NetworkBootstrap
    ) -> SyncBootstrap {
        let syncCoordinator = MainActor.assumeIsolated {
            SyncCoordinator(
                accountManager: network.accountManager,
                libraryRepository: core.libraryRepository,
                playlistRepository: core.playlistRepository,
                syncCursorRepository: core.syncCursorRepository,
                artworkDownloadManager: core.artworkDownloadManager,
                networkMonitor: network.networkMonitor,
                serverHealthChecker: network.serverHealthChecker,
                connectionRegistry: network.connectionRegistry
            )
        }

        return SyncBootstrap(syncCoordinator: syncCoordinator)
    }

    private static func buildPlaybackBootstrap(
        core: CoreBootstrap,
        network: NetworkBootstrap,
        sync: SyncBootstrap,
        foregroundWorkScheduler: ForegroundWorkScheduler
    ) -> PlaybackBootstrap {
        let lyricsService = MainActor.assumeIsolated {
            LyricsService(syncCoordinator: sync.syncCoordinator)
        }
        let artworkLoader = ArtworkLoader(
            syncCoordinator: sync.syncCoordinator,
            artworkDownloadManager: core.artworkDownloadManager
        )
        let audioAnalyzer = MainActor.assumeIsolated {
            FrequencyAnalysisService()
        }
        let trackRatingLocalStore = TrackRatingLocalStore(coreDataStack: core.coreDataStack)
        let playbackService = PlaybackService(
            syncCoordinator: sync.syncCoordinator,
            networkMonitor: network.networkMonitor,
            artworkLoader: artworkLoader,
            audioAnalyzer: audioAnalyzer,
            downloadManager: core.downloadManager,
            trackRatingLocalStore: trackRatingLocalStore,
            foregroundWorkScheduler: foregroundWorkScheduler
        )
        let cacheManager = MainActor.assumeIsolated {
            CacheManager(
                libraryRepository: core.libraryRepository,
                artworkDownloadManager: core.artworkDownloadManager,
                downloadManager: core.downloadManager,
                lyricsService: lyricsService,
                artworkCacheClear: {
                    try await artworkLoader.clearCaches()
                }
            )
        }

        #if canImport(MusicKit)
        let songLinkService = SongLinkService(searcher: MusicKitCatalogSearcher())
        #else
        let songLinkService = SongLinkService(searcher: NoOpMusicCatalogSearcher())
        #endif

        let shareService = MainActor.assumeIsolated {
            ShareService(
                songLinkService: songLinkService,
                syncCoordinator: sync.syncCoordinator
            )
        }

        return PlaybackBootstrap(
            lyricsService: lyricsService,
            artworkLoader: artworkLoader,
            audioAnalyzer: audioAnalyzer,
            playbackService: playbackService,
            cacheManager: cacheManager,
            songLinkService: songLinkService,
            shareService: shareService
        )
    }

    private static func buildMutationBootstrap(
        core: CoreBootstrap,
        network: NetworkBootstrap,
        sync: SyncBootstrap,
        playback: PlaybackBootstrap,
        foregroundWorkScheduler: ForegroundWorkScheduler
    ) -> MutationBootstrap {
        let offlineBackgroundExecutionCoordinator = MainActor.assumeIsolated {
            OfflineBackgroundExecutionCoordinator()
        }
        let offlineDownloadService = MainActor.assumeIsolated {
            OfflineDownloadService(
                downloadManager: core.downloadManager,
                targetRepository: core.offlineDownloadTargetRepository,
                libraryRepository: core.libraryRepository,
                playlistRepository: core.playlistRepository,
                syncCoordinator: sync.syncCoordinator,
                networkMonitor: network.networkMonitor,
                backgroundExecutionCoordinator: offlineBackgroundExecutionCoordinator,
                artworkDownloadManager: core.artworkDownloadManager,
                toastCenter: core.toastCenter,
                lyricsService: playback.lyricsService,
                foregroundWorkScheduler: foregroundWorkScheduler
            )
        }
        let mutationCoordinator = MainActor.assumeIsolated {
            MutationCoordinator(
                repository: core.pendingMutationRepository,
                networkMonitor: network.networkMonitor,
                syncCoordinator: sync.syncCoordinator,
                playlistRepository: core.playlistRepository
            )
        }
        let downloadMutationWorkflow = MainActor.assumeIsolated {
            DownloadMutationWorkflow(mutator: offlineDownloadService)
        }
        let playlistMutationWorkflow = MainActor.assumeIsolated {
            PlaylistMutationWorkflow(mutator: mutationCoordinator)
        }
        let trackRatingMutationWorkflow = MainActor.assumeIsolated {
            TrackRatingMutationWorkflow(mutator: mutationCoordinator)
        }
        let collectionFavoriteMutationWorkflow = MainActor.assumeIsolated {
            CollectionFavoriteMutationWorkflow(
                mutationCoordinator: mutationCoordinator,
                coreDataStack: core.coreDataStack,
                toastCenter: core.toastCenter
            )
        }
        let metadataMutationService = MainActor.assumeIsolated {
            MetadataMutationService(
                libraryRepository: core.libraryRepository,
                downloadManager: core.downloadManager,
                targetRepository: core.offlineDownloadTargetRepository,
                artworkDownloadManager: core.artworkDownloadManager,
                isOffline: { sync.syncCoordinator.isOffline },
                canManageServer: { accountId, serverId in
                    network.accountManager.plexAccounts
                        .first(where: { $0.id == accountId })?
                        .servers
                        .first(where: { $0.id == serverId })?
                        .owned ?? false
                },
                makeClient: { accountId, serverId in
                    network.accountManager.makeAPIClient(accountId: accountId, serverId: serverId)
                },
                clearLyricsCache: { ratingKey, sourceCompositeKey in
                    await playback.lyricsService.clearCache(
                        forTrackRatingKey: ratingKey,
                        sourceCompositeKey: sourceCompositeKey
                    )
                },
                removeDeletedTracksFromPlayback: { trackIDs in
                    playback.playbackService.removeDeletedTracks(trackIDs)
                }
            )
        }
        let metadataMutationWorkflow = MainActor.assumeIsolated {
            MetadataMutationWorkflow(mutator: metadataMutationService)
        }

        return MutationBootstrap(
            offlineBackgroundExecutionCoordinator: offlineBackgroundExecutionCoordinator,
            offlineDownloadService: offlineDownloadService,
            downloadMutationWorkflow: downloadMutationWorkflow,
            mutationCoordinator: mutationCoordinator,
            playlistMutationWorkflow: playlistMutationWorkflow,
            trackRatingMutationWorkflow: trackRatingMutationWorkflow,
            collectionFavoriteMutationWorkflow: collectionFavoriteMutationWorkflow,
            metadataMutationService: metadataMutationService,
            metadataMutationWorkflow: metadataMutationWorkflow
        )
    }

    private static func buildSiriBootstrap(
        core: CoreBootstrap,
        network: NetworkBootstrap,
        playback: PlaybackBootstrap,
        mutation: MutationBootstrap,
        foregroundWorkScheduler: ForegroundWorkScheduler
    ) -> SiriBootstrap {
        let enabledSystemMediaSourceKeys: SystemMediaEnabledSourceKeysProvider = { @MainActor in
            SystemMediaSourceScope.enabledLibraryKeys(for: network.accountManager.enabledSources())
        }
        let siriMediaIndexStore = MainActor.assumeIsolated {
            SiriMediaIndexStore(
                libraryRepository: core.libraryRepository,
                playlistRepository: core.playlistRepository,
                enabledSourceKeysProvider: enabledSystemMediaSourceKeys,
                hiddenMediaStore: core.hiddenMediaStore
            )
        }
        let siriPlaybackCoordinator = MainActor.assumeIsolated {
            SiriPlaybackCoordinator(
                accountManager: network.accountManager,
                libraryRepository: core.libraryRepository,
                playlistRepository: core.playlistRepository,
                playbackService: playback.playbackService,
                hiddenMediaStore: core.hiddenMediaStore
            )
        }
        let siriAffinityCoordinator = MainActor.assumeIsolated {
            SiriAffinityCoordinator(
                playbackService: playback.playbackService,
                mutationCoordinator: mutation.mutationCoordinator,
                toastCenter: core.toastCenter
            )
        }
        let siriAddToPlaylistCoordinator = MainActor.assumeIsolated {
            SiriAddToPlaylistCoordinator(
                playbackService: playback.playbackService,
                mutationCoordinator: mutation.mutationCoordinator,
                playlistRepository: core.playlistRepository,
                toastCenter: core.toastCenter
            )
        }
        let siriMediaUserContextManager = MainActor.assumeIsolated {
            SiriMediaUserContextManager(
                libraryRepository: core.libraryRepository,
                playlistRepository: core.playlistRepository,
                enabledSourceKeysProvider: enabledSystemMediaSourceKeys
            )
        }
        let systemMediaIntegrationService = MainActor.assumeIsolated {
            SystemMediaIntegrationService(
                siriMediaIndexStore: siriMediaIndexStore,
                mediaUserContextManager: siriMediaUserContextManager,
                artworkLoader: playback.artworkLoader,
                foregroundWorkScheduler: foregroundWorkScheduler
            )
        }

        return SiriBootstrap(
            siriMediaIndexStore: siriMediaIndexStore,
            siriPlaybackCoordinator: siriPlaybackCoordinator,
            siriAffinityCoordinator: siriAffinityCoordinator,
            siriAddToPlaylistCoordinator: siriAddToPlaylistCoordinator,
            siriMediaUserContextManager: siriMediaUserContextManager,
            systemMediaIntegrationService: systemMediaIntegrationService
        )
    }

    private static func buildAppBootstrapDiagnostics(
        network: NetworkBootstrap,
        sync: SyncBootstrap,
        playback: PlaybackBootstrap,
        mutation: MutationBootstrap
    ) -> AppBootstrapDiagnostics {
        AppBootstrapDiagnostics(
            dependencies: .init(
                launchTimeProvider: {
                    EnsembleStartupTiming.launchTime
                },
                accountSummaryProvider: { @MainActor in
                    let enabledSources = network.accountManager.enabledSources()
                    let selectedSource = enabledSources.first
                    let selectedServer = selectedSource.flatMap { source in
                        network.accountManager.plexAccounts
                            .first(where: { $0.id == source.accountId })?
                            .servers
                            .first(where: { $0.id == source.serverId })
                    }

                    let accountState: String
                    if network.accountManager.plexAccounts.isEmpty {
                        accountState = "no-accounts"
                    } else if enabledSources.isEmpty {
                        accountState = "accounts-loaded-no-enabled-libraries"
                    } else {
                        accountState = "ready"
                    }

                    return AppBootstrapAccountSummary(
                        accountState: accountState,
                        accountCount: network.accountManager.plexAccounts.count,
                        enabledLibraryCount: enabledSources.count,
                        selectedServerName: selectedServer?.name,
                        selectedServerKey: selectedSource.map { "\($0.accountId):\($0.serverId)" }
                    )
                },
                syncSummaryProvider: { @MainActor in
                    let readiness: String
                    if sync.syncCoordinator.isOffline {
                        readiness = "offline"
                    } else if sync.syncCoordinator.isSyncing {
                        readiness = "syncing"
                    } else if sync.syncCoordinator.lastStartupSyncCompletion != nil {
                        readiness = "ready"
                    } else {
                        readiness = "pending-startup-sync"
                    }

                    return AppBootstrapSyncSummary(
                        readiness: readiness,
                        sourceStatusCount: sync.syncCoordinator.sourceStatuses.count,
                        lastStartupSyncCompletion: sync.syncCoordinator.lastStartupSyncCompletion
                    )
                },
                playbackSummaryProvider: { @MainActor playbackRestoreWasSuppressedForSiri in
                    let restoreOutcome: String
                    if playbackRestoreWasSuppressedForSiri {
                        restoreOutcome = "skipped-because-siri-intent-pending"
                    } else {
                        switch playback.playbackService.startupRestoreStatus {
                        case .notAttempted:
                            restoreOutcome = "not-attempted"
                        case .noSnapshot:
                            restoreOutcome = "no-snapshot"
                        case .readFailed:
                            restoreOutcome = "snapshot-read-failed"
                        case .historyOnly(let count):
                            restoreOutcome = "history-only(\(count))"
                        case .skippedBecausePlaybackAlreadyActive:
                            restoreOutcome = "skipped-because-playback-already-active"
                        case .restored(let trackID, let time, let mode):
                            restoreOutcome = "restored(track=\(trackID),time=\(String(format: "%.1f", time)),mode=\(mode))"
                        }
                    }

                    return AppBootstrapPlaybackSummary(
                        restoreOutcome: restoreOutcome,
                        routeKind: playback.playbackService.currentPresentationRouteKindDescription,
                        routeDescription: playback.playbackService.currentAudioRouteDescription(),
                        audioSessionConfigured: playback.playbackService.isAudioSessionConfiguredForDiagnostics
                    )
                },
                offlineCleanupProvider: { @MainActor in
                    mutation.offlineDownloadService.lastHealingSummary
                },
                logInfo: { message in
                    EnsembleLogger.info(message)
                }
            )
        )
    }

    // MARK: - Bootstrap Wiring

    private func wireCrossSubsystemCallbacks() {
        MainActor.assumeIsolated {
            persistentLogService.installHandlers()
            wireWebSocketCallbacks()
            wireOfflineCallbacks()
            wirePlaybackCallbacks()
            wireArtworkCallbacks()
        }
    }

    @MainActor
    private func scheduleDeferredSyncStartup() {
        guard !hasScheduledDeferredSyncStartup else { return }
        hasScheduledDeferredSyncStartup = true
        cloudSyncCoordinator.wireCallbacks()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.foregroundWorkScheduler.waitUntilAllowed(.startupSync, policy: .idleOnly) else {
                EnsembleLogger.info("Sync startup: deferred iCloud/KVS bootstrap skipped because foreground work is unavailable")
                return
            }
            await self.cloudSyncCoordinator.refreshSyncState(reason: "launch")
        }
    }

    @MainActor
    private func wireWebSocketCallbacks() {
        webSocketCoordinator.onLibraryUpdate = { [weak syncCoordinator] sectionKey, serverKey, changes in
            await syncCoordinator?.syncSectionIncremental(
                sectionKey: sectionKey,
                serverKey: serverKey,
                changes: changes
            )
        }
        webSocketCoordinator.onPlaylistUpdate = { [weak syncCoordinator] serverKey in
            await syncCoordinator?.syncServerPlaylistsIncremental(serverKey: serverKey)
        }
        webSocketCoordinator.onConnectionAvailabilityChanged = { [weak syncCoordinator] hasActiveWebSocket in
            syncCoordinator?.adjustTimersForWebSocket(hasActiveWebSocket: hasActiveWebSocket)
        }
        webSocketCoordinator.onServerOffline = { [weak serverHealthChecker] serverKey in
            let parts = serverKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let serverHealthChecker else { return }
            let accountId = String(parts[0])
            let serverId = String(parts[1])
            _ = await serverHealthChecker.checkServer(accountId: accountId, serverId: serverId)
        }
        webSocketCoordinator.onServerHealthy = { [weak serverHealthChecker] serverKey in
            let parts = serverKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let serverHealthChecker else { return }
            let accountId = String(parts[0])
            let serverId = String(parts[1])
            let currentState = await MainActor.run {
                serverHealthChecker.getServerState(accountId: accountId, serverId: serverId)
            }
            if currentState.isAvailable {
                serverHealthChecker.markServerHealthy(accountId: accountId, serverId: serverId)
            } else {
                _ = await serverHealthChecker.checkServer(accountId: accountId, serverId: serverId)
            }
        }
        webSocketCoordinator.onDownloadQueueCompleted = { [weak offlineDownloadService] in
            await offlineDownloadService?.handleDownloadQueueCompleted()
        }
        webSocketCoordinator.onArtworkInvalidation = { [weak self] ratingKey, typeString in
            let type: ArtworkType
            switch typeString {
            case "album": type = .album
            case "artist": type = .artist
            default: type = .album
            }
            guard let artworkLoader = self?.artworkLoader as? ArtworkLoader else { return }
            await artworkLoader.invalidateArtwork(ratingKey: ratingKey, type: type)
        }
    }

    @MainActor
    private func wireOfflineCallbacks() {
        syncCoordinator.onPlaylistRefreshCompleted = { [weak offlineDownloadService] serverSourceKey in
            Task { @MainActor in
                await offlineDownloadService?.handlePlaylistRefreshCompleted(serverSourceKey: serverSourceKey)
            }
        }
        syncCoordinator.downloadedPlaylistServerSourceKeys = { [weak offlineDownloadService] in
            offlineDownloadService?.downloadedPlexPlaylistServerSourceKeys ?? []
        }
        syncCoordinator.onFavoritesRatingChanged = { [weak offlineDownloadService] in
            await offlineDownloadService?.reconcileFavoritesTargetIfEnabled()
        }
        offlineDownloadService.observePlayback(
            trackPublisher: playbackService.currentTrackPublisher,
            playbackStatePublisher: playbackService.playbackStatePublisher
        )
        syncCoordinator.shouldDeferForegroundHealthRefresh = { [weak offlineDownloadService] in
            offlineDownloadService?.shouldDeferForegroundHealthRefresh ?? false
        }

        var powerCancellable: AnyCancellable?
        powerCancellable = powerStateMonitor.$isLowPowerMode
            .dropFirst()
            .sink { [weak offlineDownloadService] isLowPower in
                _ = powerCancellable
                Task { @MainActor in
                    await offlineDownloadService?.setLowPowerModePaused(isLowPower)
                }
            }
    }

    @MainActor
    private func wirePlaybackCallbacks() {
        playbackService.setMutationCoordinator(mutationCoordinator)
        playbackService.onNetworkWorkPressureChanged = { [weak syncCoordinator, weak offlineDownloadService] low in
            syncCoordinator?.isPlaybackBufferLow = low
            Task { @MainActor in await offlineDownloadService?.setPlaybackBufferLow(low) }
        }
        if let audioAnalyzer = audioAnalyzer as? FrequencyAnalysisService {
            audioAnalyzer.visualizationEnabled = PlaybackSettingsObserver.visualizerEnabled(in: .standard)
        }
    }

    @MainActor
    private func wireArtworkCallbacks() {
        syncCoordinator.onConnectionsRefreshed = { [weak self] in
            await self?.artworkLoader.invalidateURLCache()
        }
        syncCoordinator.onTrackAlbumChanged = { [weak self] reparentedTracks in
            guard let artworkLoader = self?.artworkLoader as? ArtworkLoader else { return }
            await artworkLoader.invalidateArtwork(reparentedTracks.flatMap { info in
                [
                    ArtworkInvalidationInfo(
                        ratingKey: info.oldAlbumRatingKey,
                        type: .album,
                        reason: .metadataModified,
                        sourceCompositeKey: info.sourceCompositeKey
                    ),
                    ArtworkInvalidationInfo(
                        ratingKey: info.trackRatingKey,
                        type: .track,
                        reason: .metadataModified,
                        sourceCompositeKey: info.sourceCompositeKey
                    )
                ]
            })
        }
        syncCoordinator.onArtworkMetadataChanged = { [weak self] invalidations in
            guard let self, let artworkLoader = self.artworkLoader as? ArtworkLoader else { return }
            await artworkLoader.invalidateArtwork(invalidations)
            for info in invalidations {
                if info.reason == .removed, let sourceCompositeKey = info.sourceCompositeKey {
                    self.artworkDownloadManager.deleteArtwork(
                        ratingKey: info.ratingKey,
                        type: info.type,
                        sourceCompositeKey: sourceCompositeKey
                    )
                }
            }
        }
        syncCoordinator.sourceCacheCleanupService = sourceCacheCleanupService
    }

    @MainActor
    public func reconcileSyncOnForeground() async {
        await cloudSyncCoordinator.reconcileSyncOnForeground()
    }

    @MainActor
    public func runManualSync() async {
        await cloudSyncCoordinator.runManualSync()
    }

    @MainActor
    public func emitColdLaunchDiagnostics(
        playbackRestoreWasSuppressedForSiri: Bool = false
    ) async {
        await appBootstrapDiagnostics.emitColdLaunchSummary(
            playbackRestoreWasSuppressedForSiri: playbackRestoreWasSuppressedForSiri
        )
    }


}
