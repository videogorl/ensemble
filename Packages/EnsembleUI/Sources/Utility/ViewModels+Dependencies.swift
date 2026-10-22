import EnsembleCore

// Convenience initializers for view models that more than one view builds.
// View models stay independent of the container; views supply it.

public extension NowPlayingViewModel {
    /// Builds an unstarted model; the owner calls `start()` once.
    convenience init(dependencies: DependencyContainer, navigationCoordinator: NavigationCoordinator? = nil) {
        self.init(
            playbackService: dependencies.playbackService,
            syncCoordinator: dependencies.syncCoordinator,
            libraryRepository: dependencies.libraryRepository,
            navigationCoordinator: navigationCoordinator ?? dependencies.navigationCoordinator,
            toastCenter: dependencies.toastCenter,
            mutationCoordinator: dependencies.mutationCoordinator,
            trackRatingLocalStore: TrackRatingLocalStore(coreDataStack: dependencies.coreDataStack),
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            lyricsService: dependencies.lyricsService,
            artworkLoader: dependencies.artworkLoader,
            foregroundWorkScheduler: dependencies.foregroundWorkScheduler,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            libraryChanges: dependencies.libraryChanges
        )
    }
}

extension DownloadsViewModel {
    convenience init(dependencies: DependencyContainer) {
        self.init(
            offlineDownloadService: dependencies.offlineDownloadService,
            libraryRepository: dependencies.libraryRepository,
            playlistRepository: dependencies.playlistRepository,
            mutationCoordinator: dependencies.mutationCoordinator,
            accountManager: dependencies.accountManager,
            downloadManager: dependencies.downloadManager
        )
    }
}

extension PlaylistViewModel {
    convenience init(dependencies: DependencyContainer, observesExternalChanges: Bool = true) {
        self.init(
            playlistRepository: dependencies.playlistRepository,
            syncCoordinator: dependencies.syncCoordinator,
            mutationCoordinator: dependencies.mutationCoordinator,
            toastCenter: dependencies.toastCenter,
            accountManager: dependencies.accountManager,
            visibilityStore: dependencies.libraryVisibilityStore,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            settingsManager: dependencies.settingsManager,
            observesExternalChanges: observesExternalChanges,
            libraryChanges: dependencies.libraryChanges
        )
    }
}

extension AlbumDetailViewModel {
    convenience init(
        displayAlbum: DisplayAlbum,
        dependencies: DependencyContainer,
        initialTracks: [Track]? = nil,
        includesHidden: Bool = false
    ) {
        self.init(
            displayAlbum: displayAlbum,
            libraryRepository: dependencies.libraryRepository,
            syncCoordinator: dependencies.syncCoordinator,
            initialTracks: initialTracks,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            settingsManager: dependencies.settingsManager,
            includesHidden: includesHidden,
            libraryChanges: dependencies.libraryChanges
        )
    }
}

extension PlaylistDetailViewModel {
    convenience init(
        playlist: Playlist,
        dependencies: DependencyContainer,
        initialTracks: [Track]? = nil,
        initialItems: [PlaylistItem]? = nil,
        observesExternalChanges: Bool = true,
        includesHidden: Bool = false
    ) {
        self.init(
            playlist: playlist,
            playlistRepository: dependencies.playlistRepository,
            syncCoordinator: dependencies.syncCoordinator,
            mutationCoordinator: dependencies.mutationCoordinator,
            initialTracks: initialTracks,
            initialItems: initialItems,
            observesExternalChanges: observesExternalChanges,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            includesHidden: includesHidden,
            libraryChanges: dependencies.libraryChanges
        )
    }
}

extension SearchViewModel {
    convenience init(dependencies: DependencyContainer) {
        self.init(
            libraryRepository: dependencies.libraryRepository,
            playlistRepository: dependencies.playlistRepository,
            hubRepository: dependencies.hubRepository,
            moodRepository: dependencies.moodRepository,
            accountManager: dependencies.accountManager,
            visibilityStore: dependencies.libraryVisibilityStore,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            settingsManager: dependencies.settingsManager,
            syncCoordinator: dependencies.syncCoordinator,
            libraryChanges: dependencies.libraryChanges
        )
    }
}

extension ArtistDetailResolver {
    @MainActor
    init(dependencies: DependencyContainer, includesHidden: Bool = false) {
        let syncCoordinator = dependencies.syncCoordinator
        let accountManager = dependencies.accountManager
        let visibilityStore = dependencies.libraryVisibilityStore
        let hiddenMediaStore = dependencies.hiddenMediaStore
        let settingsManager = dependencies.settingsManager
        self.init(
            libraryRepository: dependencies.libraryRepository,
            remoteArtist: { id, name, sourceKey in
                try await syncCoordinator.getArtist(artistId: id, name: name, sourceKey: sourceKey)
            },
            visibleArtists: { artists in
                let source = accountManager.sourceConfigurationSnapshot
                return LibraryVisibilityFiltering.visibleArtists(
                    artists,
                    hiddenSourceCompositeKeys: visibilityStore.effectiveHiddenSourceCompositeKeys(
                        enabledSourceCompositeKeys: source.enabledSourceKeys
                    ),
                    sourceConfiguration: source.hasAnySources || !source.isAuthoritative ? source : nil,
                    hiddenMedia: includesHidden ? .empty : hiddenMediaStore.snapshot
                )
            },
            mergingPreferences: { settingsManager.mergingPreferences }
        )
    }
}
