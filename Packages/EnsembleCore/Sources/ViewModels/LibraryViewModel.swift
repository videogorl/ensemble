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
    @Published public private(set) var hasEnabledLibraries = false
    
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

    // Available genres for chip bar filtering (derived from albums/tracks)
    @Published public private(set) var availableAlbumGenres: [String] = []
    @Published public private(set) var availableTrackGenres: [String] = []
    @Published public private(set) var availableArtistGenres: [String] = []

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let toastCenter: ToastCenter
    private let accountManager: AccountManager
    private let visibilityStore: LibraryVisibilityStore
    private var cancellables = Set<AnyCancellable>()
    private var allArtists: [Artist] = []
    private var allAlbums: [Album] = []
    private var allTracks: [Track] = []
    private var allGenres: [Genre] = []

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        accountManager: AccountManager,
        visibilityStore: LibraryVisibilityStore? = nil,
        toastCenter: ToastCenter
    ) {
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore ?? .shared
        self.toastCenter = toastCenter

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

        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .map { accounts in
                accounts.contains { account in
                    account.servers.contains { server in
                        server.libraries.contains(where: \.isEnabled)
                    }
                }
            }
            .assign(to: &$hasEnabledLibraries)

        // Reflect account/library enablement changes immediately in cached browse surfaces.
        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.loadLibrary()
                }
            }
            .store(in: &cancellables)

        // Auto-reload when sync completes (full or incremental)
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] syncing in
                if !syncing {
                    // Full sync just completed, reload library
                    Task { @MainActor in
                        await self?.loadLibrary()
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-reload when any source status changes (catches WebSocket-triggered incremental syncs
        // which update sourceStatuses but don't toggle isSyncing)
        syncCoordinator.$sourceStatuses
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] statuses in
                EnsembleLogger.debug("📚 LibraryViewModel: sourceStatuses changed — \(statuses.map { "\($0.key.compositeKey): \($0.value.syncStatus)" })")
                Task { @MainActor in
                    await self?.loadLibrary()
                }
            }
            .store(in: &cancellables)

        // Save filter options when they change
        setupFilterPersistence()

        // Keep cached filtered collections in sync with their inputs
        setupComputedPipelines()
        setupVisibilityObservation()

        // Re-fetch library when download state changes so offline dimming is accurate
        observeDownloadChanges()
    }

    /// Background queue for sort/filter computation so the main thread stays responsive
    private static let computeQueue = DispatchQueue(label: "com.ensemble.library-compute", qos: .userInitiated)

    /// Wires Combine pipelines that keep the cached filtered collections up to date.
    /// Each collection is recomputed only when its relevant inputs change (not on every SwiftUI render).
    /// Sort/filter work runs on a background queue; results are delivered on main.
    private func setupComputedPipelines() {
        // Tracks: recompute when the raw list, sort option, or filter options change.
        // Debounce by 300ms to reduce main-thread layout storms during search typing
        // (heavy SwiftUI re-renders cause audio stutter with AUSoundIsolation).
        // removeDuplicates prevents no-op publishes during sync.
        Publishers.CombineLatest3($tracks, $trackSortOption, $tracksFilterOptions)
            .debounce(for: .milliseconds(300), scheduler: Self.computeQueue)
            .map { tracks, sortOption, filterOptions -> ([Track], [TrackSection]) in
                let sorted = LibraryViewModel.sortTracks(tracks, by: sortOption, direction: filterOptions.sortDirection)
                let filtered = LibraryViewModel.filterTracks(sorted, with: filterOptions)
                let sections = LibraryViewModel.computeTrackSections(from: filtered)
                return (filtered, sections)
            }
            .removeDuplicates { old, new in
                guard old.0.count == new.0.count, old.1.count == new.1.count else { return false }
                return zip(old.0, new.0).allSatisfy { $0.id == $1.id }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered, sections in
                self?.filteredTracks = filtered
                self?.trackSections = sections
            }
            .store(in: &cancellables)

        // Artists — include albums for genre filtering (artist genres derived from album genres)
        Publishers.CombineLatest4($artists, $artistSortOption, $artistsFilterOptions, $albums)
            .debounce(for: .milliseconds(300), scheduler: Self.computeQueue)
            .map { artists, sortOption, filterOptions, albums -> [Artist] in
                let sorted = LibraryViewModel.sortArtists(artists, by: sortOption, direction: filterOptions.sortDirection)
                return LibraryViewModel.filterArtists(sorted, with: filterOptions, albums: albums)
            }
            .removeDuplicates { old, new in
                guard old.count == new.count else { return false }
                return zip(old, new).allSatisfy { $0.id == $1.id }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.filteredArtists = $0 }
            .store(in: &cancellables)

        // Albums — debounce 300ms to reduce main-thread layout storms during search
        // (heavy SwiftUI re-renders cause audio stutter with AUSoundIsolation).
        // removeDuplicates prevents no-op publishes during sync.
        Publishers.CombineLatest3($albums, $albumSortOption, $albumsFilterOptions)
            .debounce(for: .milliseconds(300), scheduler: Self.computeQueue)
            .map { albums, sortOption, filterOptions -> [Album] in
                let sorted = LibraryViewModel.sortAlbums(albums, by: sortOption, direction: filterOptions.sortDirection)
                return LibraryViewModel.filterAlbums(sorted, with: filterOptions)
            }
            .removeDuplicates { old, new in
                guard old.count == new.count else { return false }
                return zip(old, new).allSatisfy { $0.id == $1.id }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.filteredAlbums = $0 }
            .store(in: &cancellables)

        // Genres (no sort option — always alphabetical) — removeDuplicates prevents no-op publishes during sync
        Publishers.CombineLatest($genres, $genresFilterOptions)
            .debounce(for: .milliseconds(300), scheduler: Self.computeQueue)
            .map { genres, filterOptions -> [Genre] in
                let sorted = LibraryViewModel.sortByCachedKey(genres, keyExtractor: { $0.title.sortingKey }, ascending: true)
                return LibraryViewModel.filterGenres(sorted, with: filterOptions)
            }
            .removeDuplicates { old, new in
                guard old.count == new.count else { return false }
                return zip(old, new).allSatisfy { $0.id == $1.id }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.filteredGenres = $0 }
            .store(in: &cancellables)

        // Available genres for chip bar filtering.
        // Derived from items that pass all NON-genre filters, so only genres
        // that will produce results are shown (e.g. singles excluded by hideSingles
        // won't contribute their genres to the chip bar).
        Publishers.CombineLatest($albums, $albumsFilterOptions)
            .debounce(for: .milliseconds(200), scheduler: Self.computeQueue)
            .map { albums, filterOptions -> [String] in
                var nonGenreOptions = filterOptions
                nonGenreOptions.selectedGenres.removeAll()
                nonGenreOptions.excludedGenres.removeAll()
                let preFiltered = Self.filterAlbums(albums, with: nonGenreOptions)
                return Self.extractUniqueGenres(from: preFiltered.flatMap(\.genres))
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.availableAlbumGenres = $0 }
            .store(in: &cancellables)

        Publishers.CombineLatest($tracks, $tracksFilterOptions)
            .debounce(for: .milliseconds(200), scheduler: Self.computeQueue)
            .map { tracks, filterOptions -> [String] in
                var nonGenreOptions = filterOptions
                nonGenreOptions.selectedGenres.removeAll()
                nonGenreOptions.excludedGenres.removeAll()
                let preFiltered = Self.filterTracks(tracks, with: nonGenreOptions)
                return Self.extractUniqueGenres(from: preFiltered.flatMap(\.genres))
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.availableTrackGenres = $0 }
            .store(in: &cancellables)

        // Artist genres: derived from albums that pass non-genre filters
        Publishers.CombineLatest($albums, $artistsFilterOptions)
            .debounce(for: .milliseconds(200), scheduler: Self.computeQueue)
            .map { albums, _ -> [String] in
                var allGenres = Set<String>()
                for album in albums where !album.genres.isEmpty {
                    album.genres.forEach { allGenres.insert($0) }
                }
                return allGenres.sorted()
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.availableArtistGenres = $0 }
            .store(in: &cancellables)
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

    private func observeDownloadChanges() {
        NotificationCenter.default.publisher(for: OfflineDownloadService.downloadsDidChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadLibrary()
                }
            }
            .store(in: &cancellables)
    }

    private func setupVisibilityObservation() {
        self.visibilityStore.$profiles
            .combineLatest(self.visibilityStore.$activeProfileID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyVisibilityToPublishedCollections()
            }
            .store(in: &cancellables)
    }

    public func loadLibrary() async {
        isLoading = true
        error = nil

        do {
            // Refresh view context to ensure merge state is current
            await libraryRepository.refreshContext()

            // Fetch and map on a background context to keep the main thread free.
            // Domain model structs (Artist, Album, Track, Genre) are value types
            // and safe to pass across threads.
            let result = try await Self.fetchAndMapInBackground()

            allArtists = result.artists
            allAlbums = result.albums
            allTracks = result.tracks
            allGenres = result.genres
            applyVisibilityToPublishedCollections()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Fetches all library entities on a background CoreData context and maps
    /// them to domain model arrays. Runs entirely off the main thread.
    private nonisolated static func fetchAndMapInBackground() async throws -> (
        artists: [Artist], albums: [Album], tracks: [Track], genres: [Genre]
    ) {
        let context = CoreDataStack.shared.newBackgroundContext()
        context.stalenessInterval = 0  // Always fresh for this one-shot fetch

        return try await context.perform {
            // Pre-compute downloaded filenames once (single directory listing
            // instead of 1400+ individual FileManager.fileExists calls)
            let downloadedFilenames: Set<String>
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: DownloadManager.downloadsDirectory,
                    includingPropertiesForKeys: nil
                )
                downloadedFilenames = Set(contents.map { $0.lastPathComponent })
            } catch {
                downloadedFilenames = []
            }

            // Fetch artists with prefetched albums
            let artistRequest = CDArtist.fetchRequest()
            artistRequest.sortDescriptors = [
                NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            ]
            artistRequest.relationshipKeyPathsForPrefetching = ["albums"]
            let cdArtists = try context.fetch(artistRequest)
            let artists = cdArtists.map { Artist(from: $0) }

            // Fetch albums with prefetched artist
            let albumRequest = CDAlbum.fetchRequest()
            albumRequest.sortDescriptors = [
                NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                NSSortDescriptor(key: "year", ascending: false)
            ]
            albumRequest.relationshipKeyPathsForPrefetching = ["artist"]
            let cdAlbums = try context.fetch(albumRequest)
            let albums = cdAlbums.map { Album(from: $0) }

            // Fetch tracks with prefetched album and artist
            let trackRequest = CDTrack.fetchRequest()
            trackRequest.sortDescriptors = [
                NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            ]
            trackRequest.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
            let cdTracks = try context.fetch(trackRequest)
            let tracks = cdTracks.map { Track(from: $0, downloadedFilenames: downloadedFilenames) }

            // Fetch genres
            let genreRequest = CDGenre.fetchRequest()
            genreRequest.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            let cdGenres = try context.fetch(genreRequest)
            let genres = cdGenres.map { Genre(from: $0) }

            return (artists, albums, tracks, genres)
        }
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
        EnsembleLogger.debug("🔄 LibraryViewModel.refreshFromServer() called")

        // Check if offline
        if syncCoordinator.isOffline {
            EnsembleLogger.debug("📴 Offline - loading from cache only")
            await loadLibrary()
            return
        }

        // Check if sync is already in progress
        if syncCoordinator.isSyncing {
            EnsembleLogger.debug("⏳ Sync already in progress - waiting for it to complete")
            toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "arrow.triangle.2.circlepath",
                    title: "Sync in progress",
                    message: "A background sync is already running.",
                    dedupeKey: "sync-already-in-progress"
                )
            )
            await loadLibrary()
            return
        }

        error = nil

        // Run sync in a detached task to avoid SwiftUI's .refreshable cancellation
        // SwiftUI can cancel the refreshable task when the view updates, but we want
        // the sync to complete regardless
        EnsembleLogger.debug("🔄 Starting incremental sync (detached)...")
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncAllIncremental()
                continuation.resume()
            }
        }
        EnsembleLogger.debug("✅ Incremental sync complete")

        // Reload from updated cache
        await loadLibrary()
    }
    
    // MARK: - Sorted Collections (instance accessors for callers that need them)

    public var sortedTracks: [Track] { LibraryViewModel.sortTracks(tracks, by: trackSortOption, direction: tracksFilterOptions.sortDirection) }
    public var sortedArtists: [Artist] { LibraryViewModel.sortArtists(artists, by: artistSortOption, direction: artistsFilterOptions.sortDirection) }
    public var sortedAlbums: [Album] { LibraryViewModel.sortAlbums(albums, by: albumSortOption, direction: albumsFilterOptions.sortDirection) }
    public var sortedGenres: [Genre] {
        Self.sortByCachedKey(genres, keyExtractor: { $0.title.sortingKey }, ascending: true)
    }

    /// Applies visibility filtering and assigns to @Published properties.
    /// Guards each assignment to avoid firing objectWillChange when content hasn't changed,
    /// which would cause spurious body re-evaluations in all subscribing views.
    private func applyVisibilityToPublishedCollections() {
        let hiddenSourceCompositeKeys = visibilityStore.hiddenSourceCompositeKeys
        let newArtists = Self.filterArtistsForVisibility(allArtists, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
        let newAlbums = Self.filterAlbumsForVisibility(allAlbums, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
        let newTracks = Self.filterTracksForVisibility(allTracks, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
        let newGenres = Self.filterGenresForVisibility(allGenres, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)

        if !Self.idsEqual(artists, newArtists) { artists = newArtists }
        if !Self.idsEqual(albums, newAlbums) { albums = newAlbums }
        if !Self.idsEqual(tracks, newTracks) { tracks = newTracks }
        if !Self.idsEqual(genres, newGenres) { genres = newGenres }
    }

    /// Fast ID-based equality check — avoids full Equatable comparison
    private static func idsEqual<T: Identifiable>(_ a: [T], _ b: [T]) -> Bool where T.ID == String {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.id == $1.id }
    }

    internal static func filterTracksForVisibility(
        _ tracks: [Track],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Track] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return tracks }
        return tracks.filter { track in
            guard let sourceKey = track.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterArtistsForVisibility(
        _ artists: [Artist],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Artist] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return artists }
        return artists.filter { artist in
            guard let sourceKey = artist.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterAlbumsForVisibility(
        _ albums: [Album],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Album] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return albums }
        return albums.filter { album in
            guard let sourceKey = album.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterGenresForVisibility(
        _ genres: [Genre],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Genre] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return genres }
        return genres.filter { genre in
            guard let sourceKey = genre.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    // MARK: - Sort Implementations (static so Combine pipelines can call them without actor capture)

    private static func sortTracks(_ tracks: [Track], by option: TrackSortOption, direction: SortDirection) -> [Track] {
        let asc = direction == .ascending
        switch option {
        case .title:
            // Pre-compute sort keys to avoid O(n log n) calls to sortingKey
            return sortByCachedKey(tracks, keyExtractor: { $0.title.sortingKey }, ascending: asc)
        case .artist:
            return sortByCachedKey(tracks, keyExtractor: { ($0.artistName ?? "").sortingKey }, ascending: asc)
        case .album:
            return sortByCachedKey(tracks, keyExtractor: { ($0.albumName ?? "").sortingKey }, ascending: asc)
        case .duration:
            return tracks.sorted { asc ? $0.duration < $1.duration : $0.duration > $1.duration }
        case .dateAdded:
            return tracks.sorted { asc
                ? ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast)
                : ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast)
            }
        case .dateModified:
            return tracks.sorted { asc
                ? ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast)
                : ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast)
            }
        case .lastPlayed:
            return tracks.sorted { asc
                ? ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast)
                : ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
            }
        case .rating:
            return tracks.sorted { asc ? $0.rating < $1.rating : $0.rating > $1.rating }
        case .playCount:
            return tracks.sorted { asc ? $0.playCount < $1.playCount : $0.playCount > $1.playCount }
        }
    }

    private static func sortArtists(_ artists: [Artist], by option: ArtistSortOption, direction: SortDirection) -> [Artist] {
        let asc = direction == .ascending
        switch option {
        case .name:
            return sortByCachedKey(artists, keyExtractor: { $0.name.sortingKey }, ascending: asc)
        case .dateAdded:
            return artists.sorted { asc
                ? ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast)
                : ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast)
            }
        case .dateModified:
            return artists.sorted { asc
                ? ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast)
                : ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast)
            }
        }
    }

    private static func sortAlbums(_ albums: [Album], by option: AlbumSortOption, direction: SortDirection) -> [Album] {
        let asc = direction == .ascending
        switch option {
        case .title:
            return sortByCachedKey(albums, keyExtractor: { $0.title.sortingKey }, ascending: asc)
        case .artist:
            return sortByCachedKey(albums, keyExtractor: { ($0.artistName ?? "").sortingKey }, ascending: asc)
        case .albumArtist:
            return sortByCachedKey(albums, keyExtractor: { ($0.albumArtist ?? "").sortingKey }, ascending: asc)
        case .year:
            return albums.sorted { asc ? ($0.year ?? 0) < ($1.year ?? 0) : ($0.year ?? 0) > ($1.year ?? 0) }
        case .dateAdded:
            return albums.sorted { asc
                ? ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast)
                : ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast)
            }
        case .dateModified:
            return albums.sorted { asc
                ? ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast)
                : ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast)
            }
        case .rating:
            return albums.sorted { asc ? $0.rating < $1.rating : $0.rating > $1.rating }
        }
    }

    /// Sort by pre-computed string keys — computes sortingKey once per element
    /// instead of O(n log n) times via repeated closure calls.
    /// Uses ID as tiebreaker for stable ordering (prevents flicker when items share the same sort key).
    private static func sortByCachedKey<T: Identifiable>(_ items: [T], keyExtractor: (T) -> String, ascending: Bool) -> [T] where T.ID == String {
        let keyed = items.map { ($0, keyExtractor($0)) }
        return keyed.sorted {
            let result = $0.1.localizedStandardCompare($1.1)
            if result == .orderedSame {
                return $0.0.id < $1.0.id
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map { $0.0 }
    }

    // MARK: - Sections

    public struct TrackSection: Identifiable {
        public let letter: String
        public let tracks: [Track]
        public var id: String { letter }
    }

    // MARK: - Filter Implementations (static so Combine pipelines can call them without actor capture)

    /// Extract unique sorted genre names from a flat list
    static func extractUniqueGenres(from names: [String]) -> [String] {
        let filtered = names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(Set(filtered)).sorted()
    }

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

        if !options.selectedGenres.isEmpty {
            filtered = filtered.filter { !options.selectedGenres.isDisjoint(with: $0.genres) }
        }

        if !options.excludedGenres.isEmpty {
            filtered = filtered.filter { !$0.genres.isEmpty && options.excludedGenres.isDisjoint(with: $0.genres) }
        }

        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return filtered
    }

    private static func filterArtists(_ artists: [Artist], with options: FilterOptions, albums: [Album] = []) -> [Artist] {
        var filtered = artists

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter { $0.name.lowercased().contains(searchLower) }
        }

        // Genre filtering: build artist-to-genres map from albums
        if !options.selectedGenres.isEmpty {
            var artistGenres: [String: Set<String>] = [:]
            for album in albums {
                guard let artistKey = album.artistRatingKey, !album.genres.isEmpty else { continue }
                artistGenres[artistKey, default: []].formUnion(album.genres)
            }
            filtered = filtered.filter { artist in
                guard let genres = artistGenres[artist.id] else { return false }
                return !options.selectedGenres.isDisjoint(with: genres)
            }
        }

        if !options.excludedGenres.isEmpty {
            var artistGenres: [String: Set<String>] = [:]
            for album in albums {
                guard let artistKey = album.artistRatingKey, !album.genres.isEmpty else { continue }
                artistGenres[artistKey, default: []].formUnion(album.genres)
            }
            filtered = filtered.filter { artist in
                guard let genres = artistGenres[artist.id], !genres.isEmpty else { return false }
                return options.excludedGenres.isDisjoint(with: genres)
            }
        }

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

        if !options.selectedGenres.isEmpty {
            filtered = filtered.filter { !options.selectedGenres.isDisjoint(with: $0.genres) }
        }

        if !options.excludedGenres.isEmpty {
            filtered = filtered.filter { !$0.genres.isEmpty && options.excludedGenres.isDisjoint(with: $0.genres) }
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

        if options.hideSingles {
            filtered = filtered.filter { $0.trackCount > 1 }
        }

        return filtered
    }

    private static func filterGenres(_ genres: [Genre], with options: FilterOptions) -> [Genre] {
        guard !options.searchText.isEmpty else { return genres }
        let searchLower = options.searchText.lowercased()
        return genres.filter { $0.title.lowercased().contains(searchLower) }
    }
}
