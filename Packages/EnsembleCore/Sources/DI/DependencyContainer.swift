import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Central dependency container that creates and wires all services and view models
public final class DependencyContainer: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = DependencyContainer()

    // MARK: - Core Services (Singletons)

    public let keychain: KeychainServiceProtocol
    public let coreDataStack: CoreDataStack
    public let apiClient: PlexAPIClient
    public let authService: PlexAuthService

    // MARK: - Repositories

    public let libraryRepository: LibraryRepositoryProtocol
    public let playlistRepository: PlaylistRepositoryProtocol
    public let downloadManager: DownloadManagerProtocol

    // MARK: - Services

    public let playbackService: PlaybackService
    public let syncService: LibrarySyncServiceProtocol
    public let artworkLoader: ArtworkLoaderProtocol

    // MARK: - Initialization

    private init() {
        // Core infrastructure
        keychain = KeychainService.shared
        coreDataStack = CoreDataStack.shared
        apiClient = PlexAPIClient(keychain: keychain)
        authService = PlexAuthService(keychain: keychain)

        // Repositories
        libraryRepository = LibraryRepository(coreDataStack: coreDataStack)
        playlistRepository = PlaylistRepository(coreDataStack: coreDataStack)
        downloadManager = DownloadManager(coreDataStack: coreDataStack)

        // Services
        playbackService = PlaybackService(apiClient: apiClient)
        syncService = LibrarySyncService(
            apiClient: apiClient,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )
        artworkLoader = ArtworkLoader(apiClient: apiClient)
    }

    // MARK: - View Model Factories

    @MainActor
    public func makeAuthViewModel() -> AuthViewModel {
        AuthViewModel(authService: authService, apiClient: apiClient)
    }

    @MainActor
    public func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: libraryRepository,
            syncService: syncService
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
            apiClient: apiClient,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makeAlbumDetailViewModel(album: Album) -> AlbumDetailViewModel {
        AlbumDetailViewModel(
            album: album,
            apiClient: apiClient,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makePlaylistViewModel() -> PlaylistViewModel {
        PlaylistViewModel(
            apiClient: apiClient,
            playlistRepository: playlistRepository
        )
    }

    @MainActor
    public func makePlaylistDetailViewModel(playlist: Playlist) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(
            playlist: playlist,
            apiClient: apiClient,
            playlistRepository: playlistRepository,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makeSearchViewModel() -> SearchViewModel {
        SearchViewModel(
            apiClient: apiClient,
            libraryRepository: libraryRepository
        )
    }

    @MainActor
    public func makeDownloadsViewModel() -> DownloadsViewModel {
        DownloadsViewModel(downloadManager: downloadManager)
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
