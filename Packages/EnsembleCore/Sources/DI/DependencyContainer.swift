import EnsembleAPI
import EnsemblePersistence
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
    public let siriMediaUserContextManager: SiriMediaUserContextManager
    public let offlineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating
    public let offlineDownloadService: OfflineDownloadService
    public let mutationCoordinator: MutationCoordinator

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

        let offlineServiceRef = MainActor.assumeIsolated {
            OfflineDownloadService(
                downloadManager: downloadManagerRef,
                targetRepository: offlineTargetRepoRef,
                libraryRepository: libraryRef,
                playlistRepository: playlistRef,
                syncCoordinator: syncCoordinatorRef,
                networkMonitor: nm,
                backgroundExecutionCoordinator: offlineBackgroundCoordinatorRef,
                artworkDownloadManager: artworkDownloadRef
            )
        }
        offlineDownloadService = offlineServiceRef

        MainActor.assumeIsolated {
            syncCoordinatorRef.onPlaylistRefreshCompleted = { [weak offlineServiceRef] serverSourceKey in
                Task { @MainActor in
                    await offlineServiceRef?.handlePlaylistRefreshCompleted(serverSourceKey: serverSourceKey)
                }
            }
        }

        // Services using sync coordinator
        // Note: artworkLoader must be created before playbackService since it's a dependency
        let artworkLoaderRef = ArtworkLoader(syncCoordinator: syncCoordinator)
        artworkLoader = artworkLoaderRef
        
        // Audio analyzer for real-time frequency analysis
        let audioAnalyzerRef = MainActor.assumeIsolated {
            AudioAnalyzer()
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

        // Settings manager
        settingsManager = MainActor.assumeIsolated {
            SettingsManager()
        }

        // Cache manager - must be initialized after downloadManager
        let downloadRef = downloadManager
        cacheManager = MainActor.assumeIsolated {
            CacheManager(
                libraryRepository: libraryRef,
                artworkDownloadManager: artworkDownloadRef,
                downloadManager: downloadRef
            )
        }
        
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

        toastCenter = MainActor.assumeIsolated {
            ToastCenter()
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

        // Mutation coordinator — unified mutation routing with offline queue support
        let mutationCoordinatorRef = MainActor.assumeIsolated {
            MutationCoordinator(
                repository: pendingMutationRepo,
                networkMonitor: nm,
                syncCoordinator: syncCoordinatorRef
            )
        }
        mutationCoordinator = mutationCoordinatorRef

        // Wire mutation coordinator into PlaybackService for offline lock-screen rating support
        MainActor.assumeIsolated {
            playbackServiceRef.setMutationCoordinator(mutationCoordinatorRef)
        }

        // Wire up artwork cache invalidation when server connections change.
        // Must be done after all properties are initialized.
        let syncRef = syncCoordinator
        MainActor.assumeIsolated {
            syncRef.onConnectionsRefreshed = { [weak artworkLoaderRef] in
                await artworkLoaderRef?.invalidateURLCache()
            }
        }
    }

    // MARK: - View Model Factories

    @MainActor
    public func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            accountManager: accountManager,
            visibilityStore: libraryVisibilityStore
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
            mutationCoordinator: mutationCoordinator
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
            mutationCoordinator: mutationCoordinator
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
            mutationCoordinator: mutationCoordinator
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
