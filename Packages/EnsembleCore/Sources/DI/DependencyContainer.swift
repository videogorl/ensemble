import CloudKit
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
    private var kvsSyncCancellables = Set<AnyCancellable>()
    private var lastSyncedAccentColor: String = AppAccentColor.blue.rawValue
    private var lastSyncedSwipeLayout: TrackSwipeLayout = .default
    private var lastSyncedPinsData: Data?
    private var syncBootstrapTask: Task<Void, Never>?
    private var firstConnectRetryTask: Task<Void, Never>?
    private var firstConnectRetryAttempt = 0
    private var lastKnownICloudAccountStatus: CKAccountStatus = .couldNotDetermine
    private var lastKnownProfileTransportState: CloudSyncService.ProfileTransportState = .unknown
    private var hasScheduledDeferredSyncStartup = false
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
        downloadMutationWorkflow = mutation.downloadMutationWorkflow
        mutationCoordinator = mutation.mutationCoordinator
        playlistMutationWorkflow = mutation.playlistMutationWorkflow
        trackRatingMutationWorkflow = mutation.trackRatingMutationWorkflow
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

        wireCrossSubsystemCallbacks()

        MainActor.assumeIsolated {
            lastSyncedAccentColor = settingsManager.accentColorName
            lastSyncedSwipeLayout = settingsManager.trackSwipeLayout
            lastSyncedPinsData = pinManager.exportPinsData()
        }

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
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.foregroundWorkScheduler.waitUntilAllowed(.startupSync, policy: .idleOnly) else {
                EnsembleLogger.info("Sync startup: deferred iCloud/KVS bootstrap skipped because foreground work is unavailable")
                return
            }
            self.wireProfileAndCloudCallbacks()
            self.wireKVSSyncCallbacks()
            await self.refreshSyncState(reason: "launch")
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

    @MainActor
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
    public func emitColdLaunchDiagnostics(
        playbackRestoreWasSuppressedForSiri: Bool = false
    ) async {
        await appBootstrapDiagnostics.emitColdLaunchSummary(
            playbackRestoreWasSuppressedForSiri: playbackRestoreWasSuppressedForSiri
        )
    }

    @MainActor
    private func refreshSyncState(
        reason: String,
        feature: SyncSettingsManager.SyncFeature? = nil
    ) async {
        if syncSettingsManager.isMasterSyncEnabled {
            lastKnownProfileTransportState = await cloudSyncService.currentProfileTransportState()
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
        case .unavailable:
            return "Profile sync is unavailable in this build."
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
                accountStatus: lastKnownICloudAccountStatus,
                profileTransportState: lastKnownProfileTransportState
            )

        let waitingForProfile =
            userProfileStore.profile.isEmpty &&
            syncSettingsManager.profileStatus.phase == .unknown &&
            !Self.isBootstrapTransportUnavailable(
                accountStatus: lastKnownICloudAccountStatus,
                profileTransportState: lastKnownProfileTransportState
            )

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
        case .hiddenItems:
            return await bootstrapHiddenMedia(reason: reason)
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
    private func bootstrapHiddenMedia(reason: String) async -> Bool {
        guard syncSettingsManager.isFeatureEnabled(.hiddenItems) else {
            syncSettingsManager.setFeatureState(.idle, for: .hiddenItems)
            return true
        }

        syncSettingsManager.setFeatureState(.bootstrapping, for: .hiddenItems)
        if let remote = await cloudSyncService.pullHiddenMedia(), !remote.isEmpty {
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

    static func isBootstrapTransportUnavailable(
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

    static func missingProfileStatusForEmptyLocalProfile(
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

    static func shouldRetryFirstConnectForSources(
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
