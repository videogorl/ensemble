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

    // Cached computed collections — updated by Combine pipelines, not on every render
    @Published public private(set) var filteredTracks: [Track] = []
    @Published public private(set) var filteredArtists: [Artist] = []
    @Published public private(set) var filteredAlbums: [Album] = []
    @Published public private(set) var filteredGenres: [Genre] = []
    @Published public private(set) var trackSections: [TrackSection] = []

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

        // Keep cached filtered collections in sync with their inputs
        setupComputedPipelines()
    }

    /// Wires Combine pipelines that keep the cached filtered collections up to date.
    /// Each collection is recomputed only when its relevant inputs change (not on every SwiftUI render).
    /// All pipeline values are passed through explicitly so no `self` capture is needed in map closures.
    private func setupComputedPipelines() {
        // Tracks: recompute when the raw list, sort option, or filter options change
        Publishers.CombineLatest3($tracks, $trackSortOption, $tracksFilterOptions)
            .map { tracks, sortOption, filterOptions -> ([Track], [TrackSection]) in
                let sorted = LibraryViewModel.sortTracks(tracks, by: sortOption)
                let filtered = LibraryViewModel.filterTracks(sorted, with: filterOptions)
                let sections = LibraryViewModel.computeTrackSections(from: filtered)
                return (filtered, sections)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered, sections in
                self?.filteredTracks = filtered
                self?.trackSections = sections
            }
            .store(in: &cancellables)

        // Artists
        Publishers.CombineLatest3($artists, $artistSortOption, $artistsFilterOptions)
            .map { artists, sortOption, filterOptions -> [Artist] in
                let sorted = LibraryViewModel.sortArtists(artists, by: sortOption)
                return LibraryViewModel.filterArtists(sorted, with: filterOptions)
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$filteredArtists)

        // Albums
        Publishers.CombineLatest3($albums, $albumSortOption, $albumsFilterOptions)
            .map { albums, sortOption, filterOptions -> [Album] in
                let sorted = LibraryViewModel.sortAlbums(albums, by: sortOption)
                return LibraryViewModel.filterAlbums(sorted, with: filterOptions)
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$filteredAlbums)

        // Genres (no sort option — always alphabetical)
        Publishers.CombineLatest($genres, $genresFilterOptions)
            .map { genres, filterOptions -> [Genre] in
                let sorted = genres.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
                return LibraryViewModel.filterGenres(sorted, with: filterOptions)
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$filteredGenres)
    }

    private static func computeTrackSections(from tracks: [Track]) -> [TrackSection] {
        let grouped = Dictionary(grouping: tracks) { $0.title.indexingLetter }
        return grouped.map { TrackSection(letter: $0.key, tracks: $0.value) }
            .sorted { left, right in
                if left.letter == "#" { return true }
                if right.letter == "#" { return false }
                return left.letter < right.letter
            }
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
            // Refresh context to ensure we get fresh data after sync
            await libraryRepository.refreshContext()

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
        #if DEBUG
        print("🔄 LibraryViewModel.refreshFromServer() called")
        #endif

        // Check if offline
        if syncCoordinator.isOffline {
            #if DEBUG
            print("📴 Offline - loading from cache only")
            #endif
            await loadLibrary()
            return
        }

        // Check if sync is already in progress
        if syncCoordinator.isSyncing {
            #if DEBUG
            print("⏳ Sync already in progress - waiting for it to complete")
            #endif
            await loadLibrary()
            return
        }

        error = nil

        // Run sync in a detached task to avoid SwiftUI's .refreshable cancellation
        // SwiftUI can cancel the refreshable task when the view updates, but we want
        // the sync to complete regardless
        #if DEBUG
        print("🔄 Starting incremental sync (detached)...")
        #endif
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncAllIncremental()
                continuation.resume()
            }
        }
        #if DEBUG
        print("✅ Incremental sync complete")
        #endif

        // Reload from updated cache
        await loadLibrary()
    }
    
    // MARK: - Sorted Collections (instance accessors for callers that need them)

    public var sortedTracks: [Track] { LibraryViewModel.sortTracks(tracks, by: trackSortOption) }
    public var sortedArtists: [Artist] { LibraryViewModel.sortArtists(artists, by: artistSortOption) }
    public var sortedAlbums: [Album] { LibraryViewModel.sortAlbums(albums, by: albumSortOption) }
    public var sortedGenres: [Genre] {
        genres.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
    }

    // MARK: - Sort Implementations (static so Combine pipelines can call them without actor capture)

    private static func sortTracks(_ tracks: [Track], by option: TrackSortOption) -> [Track] {
        switch option {
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

    private static func sortArtists(_ artists: [Artist], by option: ArtistSortOption) -> [Artist] {
        switch option {
        case .name:
            return artists.sorted { $0.name.sortingKey.localizedStandardCompare($1.name.sortingKey) == .orderedAscending }
        case .dateAdded:
            return artists.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateModified:
            return artists.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        }
    }

    private static func sortAlbums(_ albums: [Album], by option: AlbumSortOption) -> [Album] {
        switch option {
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

    // MARK: - Sections

    public struct TrackSection: Identifiable {
        public let letter: String
        public let tracks: [Track]
        public var id: String { letter }
    }

    // MARK: - Filter Implementations (static so Combine pipelines can call them without actor capture)

    private static func filterTracks(_ tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }

        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return filtered
    }

    private static func filterArtists(_ artists: [Artist], with options: FilterOptions) -> [Artist] {
        var filtered = artists

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter { $0.name.lowercased().contains(searchLower) }
        }

        // Genre filtering for artists requires album lookups — not yet implemented
        return filtered
    }

    private static func filterAlbums(_ albums: [Album], with options: FilterOptions) -> [Album] {
        var filtered = albums

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumArtist?.lowercased().contains(searchLower) ?? false)
            }
        }

        if let yearRange = options.yearRange {
            filtered = filtered.filter {
                guard let year = $0.year else { return false }
                return yearRange.contains(year)
            }
        }

        if !options.selectedArtists.isEmpty {
            filtered = filtered.filter { album in
                options.selectedArtists.contains(album.artistName ?? "") ||
                options.selectedArtists.contains(album.albumArtist ?? "")
            }
        }

        return filtered
    }

    private static func filterGenres(_ genres: [Genre], with options: FilterOptions) -> [Genre] {
        guard !options.searchText.isEmpty else { return genres }
        let searchLower = options.searchText.lowercased()
        return genres.filter { $0.title.lowercased().contains(searchLower) }
    }
}
