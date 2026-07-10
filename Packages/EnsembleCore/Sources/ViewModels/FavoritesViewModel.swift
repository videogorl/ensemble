import Combine
import EnsemblePersistence
import Foundation

/// ViewModel for Favorites view - displays tracks rated 4/5 or 5/5 stars
/// This is an offline-first hub that pulls data directly from CoreData without server requests
/// Spans all configured servers and libraries
@MainActor
public final class FavoritesViewModel: ObservableObject, MediaDetailViewModelProtocol {
    private static var lastGoodTracksSnapshot: [Track] = []

    static func resetLastGoodSnapshotForTesting() {
        lastGoodTracksSnapshot = []
    }

    @Published public private(set) var tracks: [Track] = []
    @Published public var filterOptions: FilterOptions
    @Published public var favoritesSortOption: FavoritesSortOption = .dateFavorited {
        didSet {
            filterOptions.sortBy = favoritesSortOption.rawValue
        }
    }
    @Published public private(set) var isLoading: Bool = true
    @Published public private(set) var hasLoadedTracks: Bool = false
    @Published public private(set) var error: String?
    // Pre-computed filtered+sorted tracks (avoids O(n log n) sort per body evaluation)
    @Published public private(set) var filteredTracks: [Track] = []
    // Pre-computed total duration derived from filteredTracks
    @Published public private(set) var totalDuration: String = "0 min"

    private let libraryRepository: LibraryRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(libraryRepository: LibraryRepositoryProtocol) {
        self.libraryRepository = libraryRepository

        let savedFilters = FilterPersistence.load(for: "Favorites")
        self.filterOptions = savedFilters

        // Restore sort option from persisted filters
        if let savedSort = FavoritesSortOption(rawValue: savedFilters.sortBy) {
            self.favoritesSortOption = savedSort
        }

        seedFromLastGoodSnapshotIfAvailable()
        seedFromPersistentCacheIfAvailable()
        setupFilterPersistence()
        setupFilteredTracksPipeline()
        observeReloadTriggers()

        // Initial load
        Task {
            await loadTracks()
        }
    }

    private func setupFilterPersistence() {
        FilterPersistence.observe($filterOptions, key: "Favorites", storingIn: &cancellables)
    }

    /// Reactive pipeline: recompute filteredTracks whenever inputs change.
    /// Runs filter+sort on a background queue with debouncing.
    private func setupFilteredTracksPipeline() {
        Publishers.CombineLatest3($tracks, $favoritesSortOption, $filterOptions)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] tracks, sortOption, filterOptions -> [Track] in
                guard self != nil else { return tracks }
                return FavoritesViewModel.filterAndSort(tracks, sortOption: sortOption, filterOptions: filterOptions)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filtered in
                self?.filteredTracks = filtered
                self?.totalDuration = MediaFormatters.trackCollectionDuration(filtered)
            }
            .store(in: &cancellables)
    }

    /// Loads favorite tracks directly from CoreData (offline-first)
    /// Fetches all tracks with rating >= 8 (4+ stars) across all sources
    public func loadTracks() async {
        if tracks.isEmpty {
            isLoading = true
        }
        error = nil

        do {
            // Favorites can reopen while the view context still holds stale sync placeholders.
            await libraryRepository.refreshContext()
            let favoriteTracks = try await libraryRepository.fetchFavoriteTracks()
            let nextTracks = favoriteTracks.map { Track(from: $0) }
            publishTracksIfChanged(nextTracks)
            updateLastGoodSnapshot(nextTracks)
        } catch {
            // Silently fail - offline-first means we show what we have
            self.error = error.localizedDescription
            if tracks.isEmpty {
                publishTracksIfChanged([])
            }
        }

        hasLoadedTracks = true
        isLoading = false
    }

    // MARK: - Change Observation

    private func observeReloadTriggers() {
        ViewModelNotificationObserver.observeDownloadAndMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
        }
    }

    // MARK: - Filter + Sort (static for background pipeline)

    private static func filterAndSort(_ tracks: [Track], sortOption: FavoritesSortOption, filterOptions: FilterOptions) -> [Track] {
        let filtered = MediaFilterEngine.filterTracks(tracks, with: filterOptions, configuration: .favorites)
        return sortTracks(filtered, by: sortOption, direction: filterOptions.sortDirection)
    }

    private static func sortTracks(_ tracks: [Track], by sortOption: FavoritesSortOption, direction: SortDirection) -> [Track] {
        let ascending = direction == .ascending
        switch sortOption {
        case .title:
            return tracks.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: ascending)
        case .artist:
            return tracks.sortedByCachedStringKey({ ($0.artistName ?? "").sortingKey }, ascending: ascending)
        case .album:
            return tracks.sortedByCachedStringKey({ ($0.albumName ?? "").sortingKey }, ascending: ascending)
        case .dateFavorited:
            return tracks.sorted { a, b in
                compareOptionalDates(a.lastRatedAt ?? a.dateAdded, b.lastRatedAt ?? b.dateAdded, ascending: ascending)
            }
        case .duration:
            return tracks.sortedByComparableKey(\.duration, ascending: ascending)
        case .lastPlayed:
            return tracks.sorted { a, b in
                compareOptionalDates(a.lastPlayed, b.lastPlayed, ascending: ascending)
            }
        case .rating:
            return tracks.sortedByComparableKey(\.rating, ascending: ascending)
        case .playCount:
            return tracks.sortedByComparableKey(\.playCount, ascending: ascending)
        }
    }

    /// Compares optional dates with nils sorting last regardless of direction
    private static func compareOptionalDates(_ a: Date?, _ b: Date?, ascending: Bool) -> Bool {
        switch (a, b) {
        case (.some(let aDate), .some(let bDate)):
            return ascending ? aDate < bDate : aDate > bDate
        case (.some, .none):
            return true  // Non-nil before nil
        case (.none, .some):
            return false
        case (.none, .none):
            return false
        }
    }

    private func seedFromLastGoodSnapshotIfAvailable() {
        let snapshot = Self.lastGoodTracksSnapshot
        guard !snapshot.isEmpty else { return }
        tracks = snapshot
        applyFilteredTracks(snapshot)
        hasLoadedTracks = true
    }

    private func seedFromPersistentCacheIfAvailable() {
        guard tracks.isEmpty,
              let repository = libraryRepository as? LibraryRepository,
              let snapshot = try? repository.fetchFavoriteTracksSnapshot().map({ Track(from: $0) }),
              !snapshot.isEmpty else {
            return
        }
        tracks = snapshot
        applyFilteredTracks(snapshot)
        updateLastGoodSnapshot(snapshot)
        hasLoadedTracks = true
        isLoading = false
    }

    private func publishTracksIfChanged(_ nextTracks: [Track]) {
        if tracks != nextTracks {
            tracks = nextTracks
        }
        applyFilteredTracks(nextTracks)
    }

    private func applyFilteredTracks(_ nextTracks: [Track]) {
        let filtered = Self.filterAndSort(nextTracks, sortOption: favoritesSortOption, filterOptions: filterOptions)
        if filteredTracks != filtered {
            filteredTracks = filtered
        }
        let duration = MediaFormatters.trackCollectionDuration(filtered)
        if totalDuration != duration {
            totalDuration = duration
        }
    }

    private func updateLastGoodSnapshot(_ nextTracks: [Track]) {
        guard !nextTracks.isEmpty else {
            Self.lastGoodTracksSnapshot = []
            return
        }
        if Self.lastGoodTracksSnapshot != nextTracks {
            Self.lastGoodTracksSnapshot = nextTracks
        }
    }
}
