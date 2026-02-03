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
    public let syncCoordinator: SyncCoordinator

    // MARK: - Repositories

    public let libraryRepository: LibraryRepositoryProtocol
    public let playlistRepository: PlaylistRepositoryProtocol
    public let downloadManager: DownloadManagerProtocol

    // MARK: - Services

    public let playbackService: PlaybackService
    public let artworkLoader: ArtworkLoaderProtocol

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

        // Multi-source management
        accountManager = AccountManager(keychain: keychain)
        syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )

        // Services using sync coordinator
        playbackService = PlaybackService(syncCoordinator: syncCoordinator)
        artworkLoader = ArtworkLoader(syncCoordinator: syncCoordinator)
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
        NowPlayingViewModel(playbackService: playbackService)
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
