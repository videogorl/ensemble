import EnsembleCore

// Convenience initializers for view models that more than one view builds.
// View models stay independent of the container; views supply it.

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
            observesExternalChanges: observesExternalChanges
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
            includesHidden: includesHidden
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
            includesHidden: includesHidden
        )
    }
}
