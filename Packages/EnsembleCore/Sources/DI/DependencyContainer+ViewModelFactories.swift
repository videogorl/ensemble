import EnsemblePersistence
import Foundation

// MARK: - View Model Factories

public extension DependencyContainer {
    /// The active NowPlayingViewModel from the main UI.
    /// Set by MainTabView/SidebarView so the external display SceneDelegate
    /// can observe the same instance for AirPlay screen mirroring.
    @MainActor var activeNowPlayingViewModel: NowPlayingViewModel? {
        get { activeNowPlayingViewModelStorage }
        set { activeNowPlayingViewModelStorage = newValue }
    }

    @MainActor
    func persistPlaybackStateSnapshot() {
        playbackService.persistPlaybackStateSnapshot()
    }

    @MainActor
    func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            sourceCacheCleanupService: sourceCacheCleanupService,
            accountManager: accountManager,
            visibilityStore: libraryVisibilityStore,
            toastCenter: toastCenter
        )
    }

    @MainActor
    func makeNowPlayingViewModel(
        navigationCoordinator: NavigationCoordinator? = nil
    ) -> NowPlayingViewModel {
        NowPlayingViewModel(
            playbackService: playbackService,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            navigationCoordinator: navigationCoordinator ?? self.navigationCoordinator,
            toastCenter: toastCenter,
            mutationCoordinator: mutationCoordinator,
            playlistMutationWorkflow: playlistMutationWorkflow,
            trackRatingMutationWorkflow: trackRatingMutationWorkflow,
            trackAvailabilityResolver: trackAvailabilityResolver,
            lyricsService: lyricsService
        )
    }

    @MainActor
    func makeLibraryItemInfoViewModel(request: LibraryItemInfoRequest) -> LibraryItemInfoViewModel {
        LibraryItemInfoViewModel(
            request: request,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            accountManager: accountManager
        )
    }

    @MainActor
    func makeArtistDetailViewModel(artist: Artist) -> ArtistDetailViewModel {
        ArtistDetailViewModel(
            artist: artist,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator
        )
    }

    @MainActor
    func makeMergedArtistDetailViewModel(displayArtist: DisplayArtist) -> MergedArtistDetailViewModel {
        MergedArtistDetailViewModel(
            displayArtist: displayArtist,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            accountManager: accountManager
        )
    }

    @MainActor
    func makeAlbumDetailViewModel(album: Album, initialTracks: [Track]? = nil) -> AlbumDetailViewModel {
        AlbumDetailViewModel(
            album: album,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            initialTracks: initialTracks
        )
    }

    @MainActor
    func makePlaylistViewModel() -> PlaylistViewModel {
        PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator,
            toastCenter: toastCenter,
            accountManager: accountManager
        )
    }

    @MainActor
    func makePlaylistDetailViewModel(playlist: Playlist, initialTracks: [Track]? = nil) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepository,
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator,
            initialTracks: initialTracks
        )
    }

    @MainActor
    func makeMergedPlaylistDetailViewModel(displayPlaylist: DisplayPlaylist) -> MergedPlaylistDetailViewModel {
        MergedPlaylistDetailViewModel(
            displayPlaylist: displayPlaylist,
            playlistRepository: playlistRepository,
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: mutationCoordinator
        )
    }

    @MainActor
    func makeSearchViewModel() -> SearchViewModel {
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
    func makeDownloadsViewModel() -> DownloadsViewModel {
        DownloadsViewModel(
            offlineDownloadService: offlineDownloadService,
            downloadMutationWorkflow: downloadMutationWorkflow,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            mutationCoordinator: mutationCoordinator,
            accountManager: accountManager,
            downloadManager: downloadManager
        )
    }

    @MainActor
    func makeLibraryDownloadDetailViewModel(
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
    func makeDownloadManagerSettingsViewModel() -> DownloadManagerSettingsViewModel {
        DownloadManagerSettingsViewModel(
            offlineDownloadService: offlineDownloadService,
            downloadMutationWorkflow: downloadMutationWorkflow,
            targetRepository: offlineDownloadTargetRepository,
            downloadManager: downloadManager
        )
    }

    @MainActor
    func makeDownloadTargetDetailViewModel(summary: DownloadedItemSummary) -> DownloadTargetDetailViewModel {
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
    func makeAddPlexAccountViewModel() -> AddPlexAccountViewModel {
        AddPlexAccountViewModel(
            authService: authService,
            accountDiscoveryService: accountDiscoveryService,
            accountManager: accountManager,
            syncCoordinator: syncCoordinator
        )
    }

    @MainActor
    func makeMusicSourceAccountDetailViewModel(accountId: String) -> MusicSourceAccountDetailViewModel {
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
    func makeFavoritesViewModel() -> FavoritesViewModel {
        FavoritesViewModel(libraryRepository: libraryRepository)
    }

    @MainActor
    func makePinnedViewModel() -> PinnedViewModel {
        PinnedViewModel(
            pinManager: pinManager,
            pinMutationWorkflow: pinMutationWorkflow,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )
    }

    @MainActor
    func makePendingMutationsViewModel() -> PendingMutationsViewModel {
        PendingMutationsViewModel(
            mutationCoordinator: mutationCoordinator,
            repository: PendingMutationRepository(coreDataStack: coreDataStack),
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )
    }

    @MainActor
    func makeExternalDeviceSyncViewModel() -> ExternalDeviceSyncViewModel {
        ExternalDeviceSyncViewModel(syncService: externalDeviceSyncService)
    }

    @MainActor
    func makeHomeViewModel() -> HomeViewModel {
        HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            hubLoader: homeHubLoader,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            hubOrderManager: hubOrderManager,
            visibilityStore: libraryVisibilityStore
        )
    }
}
