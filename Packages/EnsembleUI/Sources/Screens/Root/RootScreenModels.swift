import Combine
import EnsembleCore

/// Root-screen models whose identity must match the SwiftUI scene lifetime.
@MainActor
final class RootScreenModels: ObservableObject {
    let library: LibraryViewModel
    let home: HomeViewModel
    let search: SearchViewModel
    let pinned: PinnedViewModel
    let playlists: PlaylistViewModel
    let dependencies: DependencyContainer
    lazy var favorites = FavoritesViewModel(
        libraryRepository: dependencies.libraryRepository,
        accountManager: dependencies.accountManager,
        visibilityStore: dependencies.libraryVisibilityStore,
        hiddenMediaStore: dependencies.hiddenMediaStore,
        settingsManager: dependencies.settingsManager
    )
    lazy var hidden = HiddenMediaViewModel(
        store: dependencies.hiddenMediaStore,
        libraryRepository: dependencies.libraryRepository,
        playlistRepository: dependencies.playlistRepository,
        accountManager: dependencies.accountManager
    )
    lazy var downloads = DownloadsViewModel(dependencies: dependencies)

    init(dependencies: DependencyContainer = .shared) {
        self.dependencies = dependencies
        library = dependencies.makeLibraryViewModel()
        home = dependencies.makeHomeViewModel()
        search = dependencies.makeSearchViewModel()
        pinned = dependencies.makePinnedViewModel()
        playlists = PlaylistViewModel(dependencies: dependencies)
    }
}
