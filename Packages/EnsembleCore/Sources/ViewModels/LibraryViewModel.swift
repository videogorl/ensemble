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
    @Published public private(set) var isRestoringCloudSources = false
    
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
    @Published public var genreDetailAlbumSortOption: AlbumSortOption = .title {
        didSet { genreDetailAlbumFilterOptions.sortBy = genreDetailAlbumSortOption.rawValue }
    }

    // Filter options
    @Published public var tracksFilterOptions: FilterOptions
    @Published public var artistsFilterOptions: FilterOptions
    @Published public var albumsFilterOptions: FilterOptions
    @Published public var genresFilterOptions: FilterOptions
    @Published public var genreDetailAlbumFilterOptions: FilterOptions

    // Cached computed collections — updated by Combine pipelines, not on every render
    @Published public private(set) var filteredTracks: [Track] = []
    @Published public private(set) var filteredArtists: [Artist] = []
    @Published public private(set) var displayArtists: [DisplayArtist] = []
    @Published public private(set) var filteredAlbums: [Album] = []
    @Published public private(set) var filteredGenres: [DisplayGenre] = []
    @Published public private(set) var trackSections: [TrackSection] = []
    @Published public private(set) var artistSections: [ArtistSection] = []
    @Published public private(set) var albumSections: [AlbumSection] = []
    @Published public private(set) var trackBrowseSnapshot: TrackBrowseSnapshot = .empty
    @Published public private(set) var artistBrowseSnapshot: ArtistBrowseSnapshot = .empty
    @Published public private(set) var albumBrowseSnapshot: AlbumBrowseSnapshot = .empty
    @Published public private(set) var genreBrowseSnapshot: GenreBrowseSnapshot = .empty

    /// Synchronous first-frame fallback while debounced display pipelines catch up after cache loads.
    public var immediateTrackBrowseSnapshot: TrackBrowseSnapshot {
        guard !trackBrowseSnapshot.hasVisibleContent, !tracks.isEmpty else {
            return trackBrowseSnapshot
        }

        let sorted = Self.sortTracks(tracks, by: trackSortOption, direction: tracksFilterOptions.sortDirection)
        let filtered = Self.filterTracks(sorted, with: tracksFilterOptions)
        return TrackBrowseSnapshot(
            tracks: filtered,
            sections: Self.computeTrackSections(from: filtered),
            availableGenres: availableTrackGenres,
            phase: trackBrowseSnapshot.phase,
            isShowingStaleSnapshot: trackBrowseSnapshot.isShowingStaleSnapshot
        )
    }

    public var immediateArtistBrowseSnapshot: ArtistBrowseSnapshot {
        guard !artistBrowseSnapshot.hasVisibleContent, !artists.isEmpty else {
            return artistBrowseSnapshot
        }

        let sorted = Self.sortArtists(artists, by: artistSortOption, direction: artistsFilterOptions.sortDirection)
        let filtered = Self.filterArtists(sorted, with: artistsFilterOptions, albums: albums)
        let displayArtists = DisplayArtist.group(filtered)
        return ArtistBrowseSnapshot(
            artists: filtered,
            displayArtists: displayArtists,
            sections: artistSortOption == .name ? Self.computeArtistSections(from: displayArtists) : [],
            availableGenres: availableArtistGenres,
            phase: artistBrowseSnapshot.phase,
            isShowingStaleSnapshot: artistBrowseSnapshot.isShowingStaleSnapshot
        )
    }

    public var immediateAlbumBrowseSnapshot: AlbumBrowseSnapshot {
        guard !albumBrowseSnapshot.hasVisibleContent, !albums.isEmpty else {
            return albumBrowseSnapshot
        }

        let sorted = Self.sortAlbums(albums, by: albumSortOption, direction: albumsFilterOptions.sortDirection)
        let filtered = Self.filterAlbums(sorted, with: albumsFilterOptions)
        return AlbumBrowseSnapshot(
            albums: filtered,
            sections: Self.computeAlbumSections(from: filtered, sortOption: albumSortOption),
            availableGenres: availableAlbumGenres,
            phase: albumBrowseSnapshot.phase,
            isShowingStaleSnapshot: albumBrowseSnapshot.isShowingStaleSnapshot
        )
    }

    public var immediateGenreBrowseSnapshot: GenreBrowseSnapshot {
        guard !genreBrowseSnapshot.hasVisibleContent, !genres.isEmpty else {
            return genreBrowseSnapshot
        }

        let displayGenres = Self.displayGenres(from: genres, albums: albums, with: genresFilterOptions)
        return GenreBrowseSnapshot(
            displayGenres: displayGenres,
            phase: genreBrowseSnapshot.phase,
            isShowingStaleSnapshot: genreBrowseSnapshot.isShowingStaleSnapshot
        )
    }

    // Available genres for chip bar filtering (derived from albums/tracks)
    @Published public private(set) var availableAlbumGenres: [String] = []
    @Published public private(set) var availableTrackGenres: [String] = []
    @Published public private(set) var availableArtistGenres: [String] = []

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let sourceCacheCleanupService: SourceCacheCleaning
    private let toastCenter: ToastCenter
    private let accountManager: AccountManager
    private let visibilityStore: LibraryVisibilityStore
    private let appReadinessCoordinator: AppReadinessCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var cachedSourceCleanupTask: Task<Void, Never>?
    private var allArtists: [Artist] = []
    private var allAlbums: [Album] = []
    private var allTracks: [Track] = []
    private var allGenres: [Genre] = []
    private static let cachedSourceCleanupDelayNs: UInt64 = 1_000_000_000

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        sourceCacheCleanupService: SourceCacheCleaning,
        accountManager: AccountManager,
        visibilityStore: LibraryVisibilityStore? = nil,
        toastCenter: ToastCenter,
        appReadinessCoordinator: AppReadinessCoordinator? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.sourceCacheCleanupService = sourceCacheCleanupService
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore ?? .shared
        self.toastCenter = toastCenter
        self.appReadinessCoordinator = appReadinessCoordinator
        self.isRestoringCloudSources = accountManager.isAwaitingCloudSources

        // Load saved filter options
        let savedTracks = FilterPersistence.load(for: "Songs")
        let savedArtists = FilterPersistence.load(for: "Artists")
        let savedAlbums = FilterPersistence.load(for: "Albums")
        let savedGenres = FilterPersistence.load(for: "Genres")
        let savedGenreDetailAlbums = FilterPersistence.load(for: "GenreDetailAlbums")
        
        self.tracksFilterOptions = savedTracks
        self.artistsFilterOptions = savedArtists
        self.albumsFilterOptions = savedAlbums
        self.genresFilterOptions = savedGenres
        self.genreDetailAlbumFilterOptions = savedGenreDetailAlbums
        
        // Load sort options from filters
        if let saved = TrackSortOption(rawValue: savedTracks.sortBy) { self.trackSortOption = saved }
        if let saved = ArtistSortOption(rawValue: savedArtists.sortBy) { self.artistSortOption = saved }
        if let saved = AlbumSortOption(rawValue: savedAlbums.sortBy) { self.albumSortOption = saved }
        if let saved = GenreSortOption(rawValue: savedGenres.sortBy) { self.genreSortOption = saved }
        if let saved = AlbumSortOption(rawValue: savedGenreDetailAlbums.sortBy) { self.genreDetailAlbumSortOption = saved }

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

        accountManager.$isAwaitingCloudSources
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] awaiting in
                guard let self else { return }
                self.isRestoringCloudSources = awaiting
                guard !awaiting else { return }

                Task { @MainActor in
                    await self.loadLibrary()
                }
            }
            .store(in: &cancellables)

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

        // Auto-reload only when sync reports a material library change.
        // Connection/progress churn stays on sourceStatuses and should not trigger full browse reloads.
        syncCoordinator.$lastContentChange
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .filter(\.affectsLibraryBrowse)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] change in
                EnsembleLogger.debug("📚 LibraryViewModel: reloading after content change for \(change.source.compositeKey)")
                Task { @MainActor in
                    await self?.loadLibrary()
                }
            }
            .store(in: &cancellables)

        // Startup sync can repair restored metadata before the UI has a chance to
        // subscribe to granular change events. Force one post-startup reload so
        // the first launch reflects repaired genres, artwork metadata, and counts.
        syncCoordinator.$lastStartupSyncCompletion
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] _ in
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
        observeMetadataChanges()
    }

    /// Background queue for sort/filter computation so the main thread stays responsive
    private static let computeQueue = DispatchQueue(label: "com.ensemble.library-compute", qos: .userInitiated)

    /// Wires Combine pipelines that keep the cached filtered collections up to date.
    /// Each collection is recomputed only when its relevant inputs change (not on every SwiftUI render).
    /// Sort/filter work runs on a background queue; results are delivered on main.
    private func setupComputedPipelines() {
        // Tracks: recompute when the raw list, sort option, or filter options change.
        // Debounce by 100ms to coalesce search/filter typing without making tab switches feel delayed
        // (heavy SwiftUI re-renders cause audio stutter with AUSoundIsolation).
        // removeDuplicates prevents no-op publishes during sync.
        Publishers.CombineLatest3($tracks, $trackSortOption, $tracksFilterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { tracks, sortOption, filterOptions -> ([Track], [TrackSection]) in
                let sorted = LibraryViewModel.sortTracks(tracks, by: sortOption, direction: filterOptions.sortDirection)
                let filtered = LibraryViewModel.filterTracks(sorted, with: filterOptions)
                let sections = LibraryViewModel.computeTrackSections(from: filtered)
                return (filtered, sections)
            }
            .removeDuplicates { old, new in
                guard old.0.count == new.0.count, old.1.count == new.1.count else { return false }
                return zip(old.0, new.0).allSatisfy { $0.sourceScopedID == $1.sourceScopedID }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered, sections in
                self?.commitTrackSnapshot(
                    tracks: filtered,
                    sections: sections,
                    rawTrackCount: self?.tracks.count ?? 0
                )
            }
            .store(in: &cancellables)

        // Artists — include albums for genre filtering (artist genres derived from album genres)
        Publishers.CombineLatest4($artists, $artistSortOption, $artistsFilterOptions, $albums)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { artists, sortOption, filterOptions, albums -> ([Artist], [DisplayArtist], [ArtistSection]) in
                let sorted = LibraryViewModel.sortArtists(artists, by: sortOption, direction: filterOptions.sortDirection)
                let filtered = LibraryViewModel.filterArtists(sorted, with: filterOptions, albums: albums)
                let display = DisplayArtist.group(filtered)
                let sections = sortOption == .name ? LibraryViewModel.computeArtistSections(from: display) : []
                return (filtered, display, sections)
            }
            .removeDuplicates { old, new in
                guard old.0.count == new.0.count, old.1.count == new.1.count, old.2.count == new.2.count else { return false }
                return zip(old.0, new.0).allSatisfy { $0.sourceScopedID == $1.sourceScopedID }
                    && zip(old.1, new.1).allSatisfy { $0.id == $1.id }
                    && LibraryViewModel.artistSectionsEqual(old.2, new.2)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered, display, sections in
                self?.commitArtistSnapshot(
                    artists: filtered,
                    displayArtists: display,
                    sections: sections,
                    rawArtistCount: self?.artists.count ?? 0
                )
            }
            .store(in: &cancellables)

        // Albums — debounce 100ms to coalesce search/filter typing without making tab switches feel delayed
        // (heavy SwiftUI re-renders cause audio stutter with AUSoundIsolation).
        // removeDuplicates prevents no-op publishes during sync.
        Publishers.CombineLatest3($albums, $albumSortOption, $albumsFilterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { albums, sortOption, filterOptions -> ([Album], [AlbumSection]) in
                let sorted = LibraryViewModel.sortAlbums(albums, by: sortOption, direction: filterOptions.sortDirection)
                let filtered = LibraryViewModel.filterAlbums(sorted, with: filterOptions)
                let sections = LibraryViewModel.computeAlbumSections(from: filtered, sortOption: sortOption)
                return (filtered, sections)
            }
            .removeDuplicates { old, new in
                guard old.0.count == new.0.count, old.1.count == new.1.count else { return false }
                return zip(old.0, new.0).allSatisfy { $0.sourceScopedID == $1.sourceScopedID }
                    && LibraryViewModel.albumSectionsEqual(old.1, new.1)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered, sections in
                self?.commitAlbumSnapshot(
                    albums: filtered,
                    sections: sections,
                    rawAlbumCount: self?.albums.count ?? 0
                )
            }
            .store(in: &cancellables)

        // Genres (no sort option — always alphabetical) — removeDuplicates prevents no-op publishes during sync
        Publishers.CombineLatest3($genres, $albums, $genresFilterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { genres, albums, filterOptions -> [DisplayGenre] in
                LibraryViewModel.displayGenres(from: genres, albums: albums, with: filterOptions)
            }
            .removeDuplicates { old, new in
                guard old.count == new.count else { return false }
                return zip(old, new).allSatisfy { $0.id == $1.id }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.commitGenreSnapshot(displayGenres: $0, rawGenreCount: self?.genres.count ?? 0) }
            .store(in: &cancellables)

        // Available genres for chip bar filtering.
        // Derived from items that pass all NON-genre filters, so only genres
        // that will produce results are shown (e.g. singles excluded by hideSingles
        // won't contribute their genres to the chip bar).
        Publishers.CombineLatest($albums, $albumsFilterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { albums, filterOptions -> [String] in
                var nonGenreOptions = filterOptions
                nonGenreOptions.selectedGenres.removeAll()
                nonGenreOptions.excludedGenres.removeAll()
                let preFiltered = Self.filterAlbums(albums, with: nonGenreOptions)
                return Self.extractUniqueGenres(from: preFiltered.flatMap(\.genres))
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] genres in
                guard let self else { return }
                if self.availableAlbumGenres != genres {
                    self.availableAlbumGenres = genres
                }
                let next = self.albumBrowseSnapshot.updating(availableGenres: genres)
                if self.albumBrowseSnapshot != next {
                    self.albumBrowseSnapshot = next
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($tracks, $tracksFilterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { tracks, filterOptions -> [String] in
                var nonGenreOptions = filterOptions
                nonGenreOptions.selectedGenres.removeAll()
                nonGenreOptions.excludedGenres.removeAll()
                let preFiltered = Self.filterTracks(tracks, with: nonGenreOptions)
                return Self.extractUniqueGenres(from: preFiltered.flatMap(\.genres))
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] genres in
                guard let self else { return }
                if self.availableTrackGenres != genres {
                    self.availableTrackGenres = genres
                }
                let next = self.trackBrowseSnapshot.updating(availableGenres: genres)
                if self.trackBrowseSnapshot != next {
                    self.trackBrowseSnapshot = next
                }
            }
            .store(in: &cancellables)

        // Artist genres: derived from albums that pass non-genre filters
        Publishers.CombineLatest($albums, $artistsFilterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { albums, _ -> [String] in
                var allGenres = Set<String>()
                for album in albums where !album.genres.isEmpty {
                    album.genres.forEach { allGenres.insert($0) }
                }
                return allGenres.sorted()
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] genres in
                guard let self else { return }
                if self.availableArtistGenres != genres {
                    self.availableArtistGenres = genres
                }
                let next = self.artistBrowseSnapshot.updating(availableGenres: genres)
                if self.artistBrowseSnapshot != next {
                    self.artistBrowseSnapshot = next
                }
            }
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

    private static func computeArtistSections(from artists: [DisplayArtist]) -> [ArtistSection] {
        let grouped = Dictionary(grouping: artists) { $0.name.indexingLetter }
        return grouped.map { ArtistSection(letter: $0.key, artists: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    private static func computeAlbumSections(from albums: [Album], sortOption: AlbumSortOption) -> [AlbumSection] {
        let groupingKey: (Album) -> String
        switch sortOption {
        case .title:
            groupingKey = { $0.title.indexingLetter }
        case .artist:
            groupingKey = { ($0.artistName ?? "").indexingLetter }
        case .albumArtist:
            groupingKey = { ($0.albumArtist ?? "").indexingLetter }
        default:
            return []
        }

        let grouped = Dictionary(grouping: albums, by: groupingKey)
        return grouped.map { AlbumSection(letter: $0.key, albums: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    private static func artistSectionsEqual(_ old: [ArtistSection], _ new: [ArtistSection]) -> Bool {
        guard old.count == new.count else { return false }
        for (oldSection, newSection) in zip(old, new) {
            guard oldSection.letter == newSection.letter, oldSection.artists.count == newSection.artists.count else { return false }
            guard zip(oldSection.artists, newSection.artists).allSatisfy({ $0.id == $1.id }) else { return false }
        }
        return true
    }

    private static func albumSectionsEqual(_ old: [AlbumSection], _ new: [AlbumSection]) -> Bool {
        guard old.count == new.count else { return false }
        for (oldSection, newSection) in zip(old, new) {
            guard oldSection.letter == newSection.letter, oldSection.albums.count == newSection.albums.count else { return false }
            guard zip(oldSection.albums, newSection.albums).allSatisfy({ $0.id == $1.id }) else { return false }
        }
        return true
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

        $genreDetailAlbumFilterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "GenreDetailAlbums") }
            .store(in: &cancellables)
    }

    private func observeDownloadChanges() {
        ViewModelNotificationObserver.observe(
            OfflineDownloadService.downloadsDidChange,
            debounce: .milliseconds(500),
            storingIn: &cancellables
        ) { [weak self] in
            await self?.loadLibrary()
        }
    }

    private func observeMetadataChanges() {
        ViewModelNotificationObserver.observe(
            MetadataMutationService.metadataDidChange,
            debounce: .milliseconds(300),
            storingIn: &cancellables
        ) { [weak self] in
            await self?.loadLibrary()
        }
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
        setBrowsePhase(hasAnyVisibleBrowseSnapshot ? .refreshing : .loading)
        isLoading = true
        error = nil
        defer {
            isLoading = false
            let finalPhase: LibraryBrowseRefreshPhase = hasAnyVisibleBrowseSnapshot || canCommitAuthoritativeEmptyBrowseSnapshot
                ? .idle
                : .refreshing
            setBrowsePhase(finalPhase)
        }

        do {
            // Refresh view context to ensure merge state is current
            await libraryRepository.refreshContext()

            let enabledSourceKeys = Set(accountManager.enabledSources().map(\.compositeKey))
            guard let browseSourceKeys = try await reconcileCachedSourcesBeforeLoad(enabledSourceKeys: enabledSourceKeys) else {
                return
            }

            // Fetch and map on a background context to keep the main thread free.
            // Domain model structs (Artist, Album, Track, Genre) are value types
            // and safe to pass across threads.
            let result = try await Self.fetchAndMapInBackground(
                coreDataStack: Self.coreDataStack(for: libraryRepository)
            )

            allArtists = result.artists.filter { Self.isEnabledSource($0.sourceCompositeKey, enabledSourceKeys: browseSourceKeys) }
            allAlbums = result.albums.filter { Self.isEnabledSource($0.sourceCompositeKey, enabledSourceKeys: browseSourceKeys) }
            allTracks = result.tracks.filter { Self.isEnabledSource($0.sourceCompositeKey, enabledSourceKeys: browseSourceKeys) }
            allGenres = result.genres.filter { Self.isEnabledSource($0.sourceCompositeKey, enabledSourceKeys: browseSourceKeys) }
            applyVisibilityToPublishedCollections()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Keeps local library storage aligned with the account/library selection before publishing browse rows.
    private func reconcileCachedSourcesBeforeLoad(enabledSourceKeys: Set<String>) async throws -> Set<String>? {
        let cachedSourceKeys = Set(try await libraryRepository.fetchMusicSources().map(\.compositeKey))

        guard !accountManager.isAwaitingCloudSources else {
            cancelCachedSourceCleanup()
            guard !cachedSourceKeys.isEmpty else {
                EnsembleLogger.info("LibraryViewModel: preserving visible library while cloud sources are restoring")
                return nil
            }

            if enabledSourceKeys.isEmpty {
                EnsembleLogger.info("LibraryViewModel: using cached library source keys while cloud source selection is restoring")
                return cachedSourceKeys
            }

            return enabledSourceKeys
        }

        guard !enabledSourceKeys.isEmpty else {
            clearInMemoryLibrary()

            guard !accountManager.hasAnySources else {
                cancelCachedSourceCleanup()
                if !cachedSourceKeys.isEmpty {
                    EnsembleLogger.info("LibraryViewModel: preserving cached library data while no libraries are enabled")
                }
                return nil
            }

            if !cachedSourceKeys.isEmpty {
                EnsembleLogger.info("LibraryViewModel: purging cached library data because no source accounts are configured")
            }
            scheduleCachedSourceCleanup(sourceKeys: cachedSourceKeys, deleteAllLibraryData: true)
            return nil
        }

        let staleSourceKeys = cachedSourceKeys.subtracting(enabledSourceKeys)
        if !staleSourceKeys.isEmpty {
            EnsembleLogger.info("LibraryViewModel: purging cached data for \(staleSourceKeys.count) disabled library source(s)")
            scheduleCachedSourceCleanup(sourceKeys: staleSourceKeys, deleteAllLibraryData: false)
        }
        return enabledSourceKeys
    }

    private func cancelCachedSourceCleanup() {
        cachedSourceCleanupTask?.cancel()
        cachedSourceCleanupTask = nil
    }

    /// Schedules destructive stale-source cleanup outside the browse load path.
    /// Published collections are filtered by enabled source, so cleanup can run
    /// after first interaction without showing stale rows.
    private func scheduleCachedSourceCleanup(sourceKeys: Set<String>, deleteAllLibraryData: Bool) {
        guard !sourceKeys.isEmpty || deleteAllLibraryData else { return }

        cachedSourceCleanupTask?.cancel()
        let cleanupService = sourceCacheCleanupService
        cachedSourceCleanupTask = Task(priority: .utility) { [cleanupService] in
            try? await Task.sleep(nanoseconds: Self.cachedSourceCleanupDelayNs)
            guard !Task.isCancelled else { return }
            do {
                if deleteAllLibraryData {
                    _ = try await cleanupService.cleanupAllLibraryData(cachedSourceKeys: sourceKeys)
                } else {
                    for sourceKey in sourceKeys {
                        guard !Task.isCancelled else { return }
                        _ = try await cleanupService.cleanupSource(sourceKey)
                        await Task.yield()
                    }
                }
                guard !Task.isCancelled else { return }
                EnsembleLogger.info(
                    "LibraryViewModel: completed deferred cached-source cleanup (sources=\(sourceKeys.count), deleteAll=\(deleteAllLibraryData))"
                )
            } catch {
                EnsembleLogger.debug("LibraryViewModel: deferred cached-source cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearInMemoryLibrary() {
        allArtists = []
        allAlbums = []
        allTracks = []
        allGenres = []

        if !artists.isEmpty { artists = [] }
        if !albums.isEmpty { albums = [] }
        if !tracks.isEmpty { tracks = [] }
        if !genres.isEmpty { genres = [] }
        if !filteredArtists.isEmpty { filteredArtists = [] }
        if !displayArtists.isEmpty { displayArtists = [] }
        if !filteredAlbums.isEmpty { filteredAlbums = [] }
        if !filteredTracks.isEmpty { filteredTracks = [] }
        if !filteredGenres.isEmpty { filteredGenres = [] }
        if !trackSections.isEmpty { trackSections = [] }
        if !artistSections.isEmpty { artistSections = [] }
        if !albumSections.isEmpty { albumSections = [] }
        if !availableAlbumGenres.isEmpty { availableAlbumGenres = [] }
        if !availableTrackGenres.isEmpty { availableTrackGenres = [] }
        if !availableArtistGenres.isEmpty { availableArtistGenres = [] }
        commitEmptyBrowseSnapshots()
    }

    private static func isEnabledSource(_ sourceCompositeKey: String?, enabledSourceKeys: Set<String>) -> Bool {
        guard let sourceCompositeKey else { return false }
        return enabledSourceKeys.contains(sourceCompositeKey)
    }

    /// Fetches all library entities on a background CoreData context and maps
    /// them to domain model arrays. Runs entirely off the main thread.
    private nonisolated static func coreDataStack(for repository: LibraryRepositoryProtocol) -> CoreDataStack {
        (repository as? LibraryRepository)?.backingCoreDataStack ?? .shared
    }

    private nonisolated static func fetchAndMapInBackground(
        coreDataStack: CoreDataStack
    ) async throws -> (
        artists: [Artist], albums: [Album], tracks: [Track], genres: [Genre]
    ) {
        let context = coreDataStack.newBackgroundContext()
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
        genres.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: true)
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

        if !Self.idsEqual(artists, newArtists, identifier: \.sourceScopedID) { artists = newArtists }
        if !Self.idsEqual(albums, newAlbums, identifier: \.sourceScopedID) { albums = newAlbums }
        if !Self.idsEqual(tracks, newTracks, identifier: \.sourceScopedID) { tracks = newTracks }
        if !Self.idsEqual(genres, newGenres, identifier: \.id) { genres = newGenres }
        appReadinessCoordinator?.updateCachedLibraryReadiness(
            hasContent: !newArtists.isEmpty || !newAlbums.isEmpty || !newTracks.isEmpty || !newGenres.isEmpty
        )
    }

    private var hasAnyVisibleBrowseSnapshot: Bool {
        trackBrowseSnapshot.hasVisibleContent ||
            artistBrowseSnapshot.hasVisibleContent ||
            albumBrowseSnapshot.hasVisibleContent ||
            genreBrowseSnapshot.hasVisibleContent
    }

    private var canCommitAuthoritativeEmptyBrowseSnapshot: Bool {
        guard !accountManager.isAwaitingCloudSources else { return false }
        guard let readinessSnapshot = appReadinessCoordinator?.snapshot else { return true }
        guard readinessSnapshot.isBootstrapSettled else { return false }
        guard accountManager.hasAnySources else { return readinessSnapshot.canShowAddSources }
        guard !accountManager.enabledSources().isEmpty else { return !readinessSnapshot.hasEnabledLibraries }
        return true
    }

    private func setBrowsePhase(_ phase: LibraryBrowseRefreshPhase) {
        updateTrackBrowseSnapshot(trackBrowseSnapshot.updating(phase: phase))
        updateArtistBrowseSnapshot(artistBrowseSnapshot.updating(phase: phase))
        updateAlbumBrowseSnapshot(albumBrowseSnapshot.updating(phase: phase))
        updateGenreBrowseSnapshot(genreBrowseSnapshot.updating(phase: phase))
    }

    private func commitTrackSnapshot(
        tracks: [Track],
        sections: [TrackSection],
        rawTrackCount: Int
    ) {
        guard rawTrackCount > 0 || !trackBrowseSnapshot.hasVisibleContent || canCommitAuthoritativeEmptyBrowseSnapshot else {
            updateTrackBrowseSnapshot(trackBrowseSnapshot.updating(isShowingStaleSnapshot: true))
            return
        }

        if !Self.idsEqual(filteredTracks, tracks, identifier: \.sourceScopedID) { filteredTracks = tracks }
        if trackSections != sections { trackSections = sections }

        updateTrackBrowseSnapshot(
            TrackBrowseSnapshot(
                tracks: tracks,
                sections: sections,
                availableGenres: availableTrackGenres,
                phase: trackBrowseSnapshot.phase,
                isShowingStaleSnapshot: false
            )
        )
    }

    private func commitArtistSnapshot(
        artists: [Artist],
        displayArtists: [DisplayArtist],
        sections: [ArtistSection],
        rawArtistCount: Int
    ) {
        guard rawArtistCount > 0 || !artistBrowseSnapshot.hasVisibleContent || canCommitAuthoritativeEmptyBrowseSnapshot else {
            updateArtistBrowseSnapshot(artistBrowseSnapshot.updating(isShowingStaleSnapshot: true))
            return
        }

        if !Self.idsEqual(filteredArtists, artists, identifier: \.sourceScopedID) { filteredArtists = artists }
        if !Self.idsEqual(self.displayArtists, displayArtists, identifier: \.id) { self.displayArtists = displayArtists }
        if artistSections != sections { artistSections = sections }

        updateArtistBrowseSnapshot(
            ArtistBrowseSnapshot(
                artists: artists,
                displayArtists: displayArtists,
                sections: sections,
                availableGenres: availableArtistGenres,
                phase: artistBrowseSnapshot.phase,
                isShowingStaleSnapshot: false
            )
        )
    }

    private func commitAlbumSnapshot(
        albums: [Album],
        sections: [AlbumSection],
        rawAlbumCount: Int
    ) {
        guard rawAlbumCount > 0 || !albumBrowseSnapshot.hasVisibleContent || canCommitAuthoritativeEmptyBrowseSnapshot else {
            updateAlbumBrowseSnapshot(albumBrowseSnapshot.updating(isShowingStaleSnapshot: true))
            return
        }

        if !Self.idsEqual(filteredAlbums, albums, identifier: \.sourceScopedID) { filteredAlbums = albums }
        if albumSections != sections { albumSections = sections }

        updateAlbumBrowseSnapshot(
            AlbumBrowseSnapshot(
                albums: albums,
                sections: sections,
                availableGenres: availableAlbumGenres,
                phase: albumBrowseSnapshot.phase,
                isShowingStaleSnapshot: false
            )
        )
    }

    private func commitGenreSnapshot(displayGenres: [DisplayGenre], rawGenreCount: Int) {
        guard rawGenreCount > 0 || !genreBrowseSnapshot.hasVisibleContent || canCommitAuthoritativeEmptyBrowseSnapshot else {
            updateGenreBrowseSnapshot(genreBrowseSnapshot.updating(isShowingStaleSnapshot: true))
            return
        }

        if !Self.idsEqual(filteredGenres, displayGenres, identifier: \.id) { filteredGenres = displayGenres }
        updateGenreBrowseSnapshot(
            GenreBrowseSnapshot(
                displayGenres: displayGenres,
                phase: genreBrowseSnapshot.phase,
                isShowingStaleSnapshot: false
            )
        )
    }

    private func commitEmptyBrowseSnapshots() {
        guard canCommitAuthoritativeEmptyBrowseSnapshot else {
            setBrowsePhase(.refreshing)
            return
        }

        updateTrackBrowseSnapshot(.empty.updating(availableGenres: availableTrackGenres, phase: trackBrowseSnapshot.phase))
        updateArtistBrowseSnapshot(.empty.updating(availableGenres: availableArtistGenres, phase: artistBrowseSnapshot.phase))
        updateAlbumBrowseSnapshot(.empty.updating(availableGenres: availableAlbumGenres, phase: albumBrowseSnapshot.phase))
        updateGenreBrowseSnapshot(.empty.updating(phase: genreBrowseSnapshot.phase))
    }

    private func updateTrackBrowseSnapshot(_ snapshot: TrackBrowseSnapshot) {
        if trackBrowseSnapshot != snapshot {
            trackBrowseSnapshot = snapshot
        }
    }

    private func updateArtistBrowseSnapshot(_ snapshot: ArtistBrowseSnapshot) {
        if artistBrowseSnapshot != snapshot {
            artistBrowseSnapshot = snapshot
        }
    }

    private func updateAlbumBrowseSnapshot(_ snapshot: AlbumBrowseSnapshot) {
        if albumBrowseSnapshot != snapshot {
            albumBrowseSnapshot = snapshot
        }
    }

    private func updateGenreBrowseSnapshot(_ snapshot: GenreBrowseSnapshot) {
        if genreBrowseSnapshot != snapshot {
            genreBrowseSnapshot = snapshot
        }
    }

    /// Fast ID-based equality check — avoids full Equatable comparison
    private static func idsEqual<T>(_ a: [T], _ b: [T], identifier: (T) -> String) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { identifier($0) == identifier($1) }
    }

    internal static func filterTracksForVisibility(
        _ tracks: [Track],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Track] {
        LibraryVisibilityFiltering.visibleItems(tracks, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
    }

    internal static func filterArtistsForVisibility(
        _ artists: [Artist],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Artist] {
        LibraryVisibilityFiltering.visibleItems(artists, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
    }

    internal static func filterAlbumsForVisibility(
        _ albums: [Album],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Album] {
        LibraryVisibilityFiltering.visibleItems(albums, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
    }

    internal static func filterGenresForVisibility(
        _ genres: [Genre],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Genre] {
        LibraryVisibilityFiltering.visibleItems(genres, hiddenSourceCompositeKeys: hiddenSourceCompositeKeys)
    }

    // MARK: - Sort Implementations (static so Combine pipelines can call them without actor capture)

    private static func sortTracks(_ tracks: [Track], by option: TrackSortOption, direction: SortDirection) -> [Track] {
        let asc = direction == .ascending
        switch option {
        case .title:
            return tracks.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: asc)
        case .artist:
            return tracks.sortedByCachedStringKey({ ($0.artistName ?? "").sortingKey }, ascending: asc)
        case .album:
            return tracks.sortedByCachedStringKey({ ($0.albumName ?? "").sortingKey }, ascending: asc)
        case .duration:
            return tracks.sortedByComparableKey(\.duration, ascending: asc)
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
            return tracks.sortedByComparableKey(\.rating, ascending: asc)
        case .playCount:
            return tracks.sortedByComparableKey(\.playCount, ascending: asc)
        }
    }

    private static func sortArtists(_ artists: [Artist], by option: ArtistSortOption, direction: SortDirection) -> [Artist] {
        let asc = direction == .ascending
        switch option {
        case .name:
            return artists.sortedByCachedStringKey({ $0.name.sortingKey }, ascending: asc)
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
            return albums.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: asc)
        case .artist:
            return albums.sortedByCachedStringKey({ ($0.artistName ?? "").sortingKey }, ascending: asc)
        case .albumArtist:
            return albums.sortedByCachedStringKey({ ($0.albumArtist ?? "").sortingKey }, ascending: asc)
        case .year:
            return albums.sortedByComparableKey({ $0.year ?? 0 }, ascending: asc)
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
            return albums.sortedByComparableKey(\.rating, ascending: asc)
        }
    }

    // MARK: - Sections

    public struct TrackSection: Identifiable, Equatable, Sendable {
        public let letter: String
        public let tracks: [Track]
        public var id: String { letter }
    }

    public struct ArtistSection: Identifiable, Equatable, Sendable {
        public let letter: String
        public let artists: [DisplayArtist]
        public var id: String { letter }
    }

    public struct AlbumSection: Identifiable, Equatable, Sendable {
        public let letter: String
        public let albums: [Album]
        public var id: String { letter }

        public init(letter: String, albums: [Album]) {
            self.letter = letter
            self.albums = albums
        }
    }

    // MARK: - Filter Implementations (static so Combine pipelines can call them without actor capture)

    /// Extract unique sorted genre names from a flat list
    static func extractUniqueGenres(from names: [String]) -> [String] {
        let filtered = names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(Set(filtered)).sorted()
    }

    private static func filterTracks(_ tracks: [Track], with options: FilterOptions) -> [Track] {
        MediaFilterEngine.filterTracks(tracks, with: options, configuration: .library)
    }

    private static func filterArtists(_ artists: [Artist], with options: FilterOptions, albums: [Album] = []) -> [Artist] {
        MediaFilterEngine.filterArtists(artists, with: options, albums: albums)
    }

    private static func filterAlbums(_ albums: [Album], with options: FilterOptions) -> [Album] {
        MediaFilterEngine.filterAlbums(albums, with: options, configuration: .library)
    }

    private static func filterGenres(_ genres: [Genre], with options: FilterOptions) -> [Genre] {
        MediaFilterEngine.filterGenres(genres, with: options)
    }

    static func displayGenres(from genres: [Genre], albums: [Album], with options: FilterOptions) -> [DisplayGenre] {
        let albumGenreTitles = Set(albums.flatMap(\.genres).map(DisplayGenre.normalizedTitle))
        let sorted = genres.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: true)
        let albumBacked = sorted.filter { albumGenreTitles.contains(DisplayGenre.normalizedTitle($0.title)) }
        let filtered = Self.filterGenres(albumBacked, with: options)
        return DisplayGenre.group(filtered)
    }
}
