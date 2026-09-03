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
    private let dependencies: DependencyContainer
    lazy var favorites = dependencies.makeFavoritesViewModel()
    lazy var hidden = dependencies.makeHiddenMediaViewModel()
    lazy var downloads = dependencies.makeDownloadsViewModel()

    init(dependencies: DependencyContainer = .shared) {
        self.dependencies = dependencies
        library = dependencies.makeLibraryViewModel()
        home = dependencies.makeHomeViewModel()
        search = dependencies.makeSearchViewModel()
        pinned = dependencies.makePinnedViewModel()
        playlists = dependencies.makePlaylistViewModel()
    }
}
