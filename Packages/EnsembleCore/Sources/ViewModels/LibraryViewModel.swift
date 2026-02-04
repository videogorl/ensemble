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
    
    // Sort preferences
    @Published public var trackSortOption: TrackSortOption = .title
    @Published public var artistSortOption: ArtistSortOption = .name
    @Published public var albumSortOption: AlbumSortOption = .title
    @Published public var genreSortOption: GenreSortOption = .title

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
    
    // MARK: - Sorted Collections
    
    public var sortedTracks: [Track] {
        switch trackSortOption {
        case .title:
            return tracks.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
        case .artist:
            return tracks.sorted { 
                ($0.artistName ?? "").sortingKey.localizedStandardCompare(($1.artistName ?? "").sortingKey) == .orderedAscending
            }
        case .album:
            return tracks.sorted { 
                ($0.albumName ?? "").sortingKey.localizedStandardCompare(($1.albumName ?? "").sortingKey) == .orderedAscending
            }
        case .duration:
            return tracks.sorted { $0.duration < $1.duration }
        case .dateAdded:
            return tracks.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateModified:
            return tracks.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        case .lastPlayed:
            return tracks.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .rating:
            return tracks.sorted { $0.rating > $1.rating }
        case .playCount:
            return tracks.sorted { $0.playCount > $1.playCount }
        }
    }
    
    public var sortedArtists: [Artist] {
        switch artistSortOption {
        case .name:
            return artists.sorted { $0.name.sortingKey.localizedStandardCompare($1.name.sortingKey) == .orderedAscending }
        case .dateAdded:
            return artists.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateModified:
            return artists.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        }
    }
    
    public var sortedAlbums: [Album] {
        switch albumSortOption {
        case .title:
            return albums.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
        case .artist:
            return albums.sorted { 
                ($0.artistName ?? "").sortingKey.localizedStandardCompare(($1.artistName ?? "").sortingKey) == .orderedAscending
            }
        case .albumArtist:
            return albums.sorted {
                ($0.albumArtist ?? "").sortingKey.localizedStandardCompare(($1.albumArtist ?? "").sortingKey) == .orderedAscending
            }
        case .year:
            return albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .dateAdded:
            return albums.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateModified:
            return albums.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        case .rating:
            return albums.sorted { $0.rating > $1.rating }
        }
    }
    
    public var sortedGenres: [Genre] {
        genres.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
    }
}
