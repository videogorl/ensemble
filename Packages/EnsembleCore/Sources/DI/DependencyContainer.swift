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
    public let pendingMutationQueue: PendingMutationQueue

    // MARK: - Legacy (kept for add-account flow)

    public let authService: PlexAuthService

    // MARK: - Initialization

    private init() {
        // Core infrastructure
        keychain = KeychainService.shared
        coreDataStack = CoreDataStack.shared
        authService = PlexAuthService(keychain: keychain)

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
            AccountManager(keychain: keychainRef)
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
            ServerHealthChecker(accountManager: am, networkMonitor: nm)
        }
        serverHealthChecker = shc

        syncCoordinator = MainActor.assumeIsolated {
            SyncCoordinator(
                accountManager: am,
                libraryRepository: libraryRef,
                playlistRepository: playlistRef,
                artworkDownloadManager: artworkDownloadRef,
                networkMonitor: nm,
                serverHealthChecker: shc
            )
        }
        let syncCoordinatorRef = syncCoordinator

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

        // Pending mutation queue — drains offline mutations when connectivity resumes
        pendingMutationQueue = MainActor.assumeIsolated {
            PendingMutationQueue(
                repository: pendingMutationRepo,
                networkMonitor: nm,
                syncCoordinator: syncCoordinatorRef
            )
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
            pendingMutationQueue: pendingMutationQueue
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
            syncCoordinator: syncCoordinator
        )
    }

    @MainActor
    public func makePlaylistDetailViewModel(playlist: Playlist) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepository,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator
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
            pendingMutationQueue: pendingMutationQueue
        )
    }

    @MainActor
    public func makeDownloadManagerSettingsViewModel() -> DownloadManagerSettingsViewModel {
        DownloadManagerSettingsViewModel(offlineDownloadService: offlineDownloadService)
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
            pendingMutationQueue: pendingMutationQueue
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
            pendingMutationQueue: pendingMutationQueue,
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
