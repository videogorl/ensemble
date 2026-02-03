import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var artists: [Artist] = []
    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var genres: [Genre] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var isSyncing = false
    @Published public private(set) var hasAnySources = false

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let accountManager: AccountManager
    private var cancellables = Set<AnyCancellable>()

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        accountManager: AccountManager
    ) {
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.accountManager = accountManager

        // Observe sync state
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSyncing)

        // Observe account state
        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .map { !$0.isEmpty }
            .assign(to: &$hasAnySources)

        // Auto-reload when sync completes
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] syncing in
                if !syncing {
                    // Sync just completed, reload library
                    Task { @MainActor in
                        await self?.loadLibrary()
                    }
                }
            }
            .store(in: &cancellables)
    }

    public func loadLibrary() async {
        isLoading = true
        error = nil

        do {
            async let artistsTask = libraryRepository.fetchArtists()
            async let albumsTask = libraryRepository.fetchAlbums()
            async let tracksTask = libraryRepository.fetchTracks()
            async let genresTask = libraryRepository.fetchGenres()

            let (fetchedArtists, fetchedAlbums, fetchedTracks, fetchedGenres) = try await (
                artistsTask,
                albumsTask,
                tracksTask,
                genresTask
            )

            artists = fetchedArtists.map { Artist(from: $0) }
            albums = fetchedAlbums.map { Album(from: $0) }
            tracks = fetchedTracks.map { Track(from: $0) }
            genres = fetchedGenres.map { Genre(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func syncLibrary() async {
        error = nil
        await syncCoordinator.syncAll()
        await loadLibrary()
    }

    public func refresh() async {
        // Always load from CoreData cache
        await loadLibrary()
    }
}
