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
    @Published public var trackSortOption: TrackSortOption = .title {
        didSet { tracksFilterOptions.sortBy = trackSortOption.rawValue }
    }
    @Published public var artistSortOption: ArtistSortOption = .name {
        didSet { artistsFilterOptions.sortBy = artistSortOption.rawValue }
    }
    @Published public var albumSortOption: AlbumSortOption = .title {
        didSet { albumsFilterOptions.sortBy = albumSortOption.rawValue }
    }
    @Published public var genreSortOption: GenreSortOption = .title {
        didSet { genresFilterOptions.sortBy = genreSortOption.rawValue }
    }

    // Filter options
    @Published public var tracksFilterOptions: FilterOptions
    @Published public var artistsFilterOptions: FilterOptions
    @Published public var albumsFilterOptions: FilterOptions
    @Published public var genresFilterOptions: FilterOptions

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

        // Load saved filter options
        let savedTracks = FilterPersistence.load(for: "Songs")
        let savedArtists = FilterPersistence.load(for: "Artists")
        let savedAlbums = FilterPersistence.load(for: "Albums")
        let savedGenres = FilterPersistence.load(for: "Genres")
        
        self.tracksFilterOptions = savedTracks
        self.artistsFilterOptions = savedArtists
        self.albumsFilterOptions = savedAlbums
        self.genresFilterOptions = savedGenres
        
        // Load sort options from filters
        if let saved = TrackSortOption(rawValue: savedTracks.sortBy) { self.trackSortOption = saved }
        if let saved = ArtistSortOption(rawValue: savedArtists.sortBy) { self.artistSortOption = saved }
        if let saved = AlbumSortOption(rawValue: savedAlbums.sortBy) { self.albumSortOption = saved }
        if let saved = GenreSortOption(rawValue: savedGenres.sortBy) { self.genreSortOption = saved }

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

        // Save filter options when they change
        setupFilterPersistence()
    }

    private func setupFilterPersistence() {
        $tracksFilterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Songs") }
            .store(in: &cancellables)

        $artistsFilterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Artists") }
            .store(in: &cancellables)

        $albumsFilterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Albums") }
            .store(in: &cancellables)

        $genresFilterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Genres") }
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
    
    /// Refresh from server (incremental sync) if online, otherwise load from cache
    public func refreshFromServer() async {
        print("🔄 LibraryViewModel.refreshFromServer() called")

        // Check if offline
        if syncCoordinator.isOffline {
            print("📴 Offline - loading from cache only")
            await loadLibrary()
            return
        }

        // Check if sync is already in progress
        if syncCoordinator.isSyncing {
            print("⏳ Sync already in progress - waiting for it to complete")
            await loadLibrary()
            return
        }

        error = nil

        // Run sync in a detached task to avoid SwiftUI's .refreshable cancellation
        // SwiftUI can cancel the refreshable task when the view updates, but we want
        // the sync to complete regardless
        print("🔄 Starting incremental sync (detached)...")
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncAllIncremental()
                continuation.resume()
            }
        }
        print("✅ Incremental sync complete")

        // Reload from updated cache
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

    // MARK: - Filtered Collections

    /// Filtered and sorted tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: sortedTracks, with: tracksFilterOptions)
    }

    /// Filtered and sorted artists based on current filter options
    public var filteredArtists: [Artist] {
        applyFilters(to: sortedArtists, with: artistsFilterOptions)
    }

    /// Filtered and sorted albums based on current filter options
    public var filteredAlbums: [Album] {
        applyFilters(to: sortedAlbums, with: albumsFilterOptions)
    }

    /// Filtered and sorted genres based on current filter options
    public var filteredGenres: [Genre] {
        applyFilters(to: sortedGenres, with: genresFilterOptions)
    }

    // MARK: - Sections

    public struct TrackSection: Identifiable {
        public let letter: String
        public let tracks: [Track]
        public var id: String { letter }
    }

    public var trackSections: [TrackSection] {
        let grouped = Dictionary(grouping: filteredTracks) { $0.title.indexingLetter }
        return grouped.map { TrackSection(letter: $0.key, tracks: $0.value) }
            .sorted { left, right in
                if left.letter == "#" { return true }
                if right.letter == "#" { return false }
                return left.letter < right.letter
            }
    }

    // MARK: - Filter Application

    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks

        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }

        // Downloaded only filter
        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return filtered
    }

    private func applyFilters(to artists: [Artist], with options: FilterOptions) -> [Artist] {
        var filtered = artists

        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.name.lowercased().contains(searchLower)
            }
        }

        // Genre filter
        if !options.selectedGenres.isEmpty {
            filtered = filtered.filter { artist in
                // For now, we can't easily filter artists by genre without fetching their albums
                // This would require additional repository methods
                true
            }
        }

        return filtered
    }

    private func applyFilters(to albums: [Album], with options: FilterOptions) -> [Album] {
        var filtered = albums

        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumArtist?.lowercased().contains(searchLower) ?? false)
            }
        }

        // Year range filter
        if let yearRange = options.yearRange {
            filtered = filtered.filter {
                guard let year = $0.year else { return false }
                return yearRange.contains(year)
            }
        }

        // Artist filter
        if !options.selectedArtists.isEmpty {
            filtered = filtered.filter { album in
                options.selectedArtists.contains(album.artistName ?? "") ||
                options.selectedArtists.contains(album.albumArtist ?? "")
            }
        }

        return filtered
    }

    private func applyFilters(to genres: [Genre], with options: FilterOptions) -> [Genre] {
        var filtered = genres

        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower)
            }
        }

        return filtered
    }
}
