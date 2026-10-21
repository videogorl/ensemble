import Combine
import EnsembleCore

/// Root-screen models whose identity must match the SwiftUI scene lifetime.
/// It publishes nothing; it stays an ObservableObject so `@StateObject` gives
/// it lazy, once-per-scene ownership, which `@State` cannot on iOS 17.
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

    init(dependencies: DependencyContainer) {
        self.dependencies = dependencies
        library = LibraryViewModel(
            libraryRepository: dependencies.libraryRepository,
            syncCoordinator: dependencies.syncCoordinator,
            accountManager: dependencies.accountManager,
            settingsManager: dependencies.settingsManager,
            visibilityStore: dependencies.libraryVisibilityStore,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            toastCenter: dependencies.toastCenter,
            appReadinessCoordinator: dependencies.appReadinessCoordinator
        )
        home = HomeViewModel(
            accountManager: dependencies.accountManager,
            syncCoordinator: dependencies.syncCoordinator,
            hubLoader: dependencies.homeHubLoader,
            libraryRepository: dependencies.libraryRepository,
            playlistRepository: dependencies.playlistRepository,
            hubOrderManager: dependencies.hubOrderManager,
            visibilityStore: dependencies.libraryVisibilityStore,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            appReadinessCoordinator: dependencies.appReadinessCoordinator
        )
        search = SearchViewModel(dependencies: dependencies)
        pinned = PinnedViewModel(
            pinManager: dependencies.pinManager,
            libraryRepository: dependencies.libraryRepository,
            playlistRepository: dependencies.playlistRepository,
            accountManager: dependencies.accountManager,
            visibilityStore: dependencies.libraryVisibilityStore,
            hiddenMediaStore: dependencies.hiddenMediaStore
        )
        playlists = PlaylistViewModel(dependencies: dependencies)
    }
}
