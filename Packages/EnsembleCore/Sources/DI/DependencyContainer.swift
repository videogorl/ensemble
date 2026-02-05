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

    nonisolated(unsafe) public let accountManager: AccountManager
    nonisolated(unsafe) public let syncCoordinator: SyncCoordinator

    // MARK: - Repositories

    public let libraryRepository: LibraryRepositoryProtocol
    public let playlistRepository: PlaylistRepositoryProtocol
    public let downloadManager: DownloadManagerProtocol
    public let artworkDownloadManager: ArtworkDownloadManagerProtocol

    // MARK: - Services

    nonisolated(unsafe) public let networkMonitor: NetworkMonitor
    nonisolated(unsafe) public let serverHealthChecker: ServerHealthChecker
    public let playbackService: PlaybackService
    public let artworkLoader: ArtworkLoaderProtocol
    nonisolated(unsafe) public let settingsManager: SettingsManager
    nonisolated(unsafe) public let cacheManager: CacheManager
    nonisolated(unsafe) public let navigationCoordinator: NavigationCoordinator

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
        downloadManager = DownloadManager(coreDataStack: coreDataStack)
        artworkDownloadManager = ArtworkDownloadManager(coreDataStack: coreDataStack)

        // Multi-source management - initialize on main actor
        let keychainRef = keychain
        let libraryRef = libraryRepository
        let playlistRef = playlistRepository
        let artworkDownloadRef = artworkDownloadManager

        let am = MainActor.assumeIsolated {
            AccountManager(keychain: keychainRef)
        }
        accountManager = am

        // Network monitoring (must be created before SyncCoordinator)
        let nm = MainActor.assumeIsolated {
            NetworkMonitor()
        }
        networkMonitor = nm

        // Server health checking (must be created before SyncCoordinator)
        let shc = MainActor.assumeIsolated {
            ServerHealthChecker(accountManager: am)
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

        // Services using sync coordinator
        playbackService = PlaybackService(syncCoordinator: syncCoordinator)
        artworkLoader = ArtworkLoader(syncCoordinator: syncCoordinator)

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
    }

    // MARK: - View Model Factories

    @MainActor
    public func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            accountManager: accountManager
        )
    }

    @MainActor
    public func makeNowPlayingViewModel() -> NowPlayingViewModel {
        NowPlayingViewModel(
            playbackService: playbackService,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            navigationCoordinator: navigationCoordinator
        )
    }

    @MainActor
    public func makeArtistDetailViewModel(artist: Artist) -> ArtistDetailViewModel {
        ArtistDetailViewModel(
            artist: artist,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makeAlbumDetailViewModel(album: Album) -> AlbumDetailViewModel {
        AlbumDetailViewModel(
            album: album,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makePlaylistViewModel() -> PlaylistViewModel {
        PlaylistViewModel(
            playlistRepository: playlistRepository
        )
    }

    @MainActor
    public func makePlaylistDetailViewModel(playlist: Playlist) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepository,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makeSearchViewModel() -> SearchViewModel {
        SearchViewModel(
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makeDownloadsViewModel() -> DownloadsViewModel {
        DownloadsViewModel(downloadManager: downloadManager)
    }

    @MainActor
    public func makeAddPlexAccountViewModel() -> AddPlexAccountViewModel {
        AddPlexAccountViewModel(
            authService: authService,
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            keychain: keychain
        )
    }

    @MainActor
    public func makeSyncPanelViewModel() -> SyncPanelViewModel {
        SyncPanelViewModel(
            syncCoordinator: syncCoordinator,
            accountManager: accountManager
        )
    }
    
    @MainActor
    public func makeFavoritesViewModel() -> FavoritesViewModel {
        FavoritesViewModel(libraryRepository: libraryRepository)
    }
    
    @MainActor
    public func makeHomeViewModel() -> HomeViewModel {
        HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator
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
