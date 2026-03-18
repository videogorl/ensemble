import Combine
import EnsemblePersistence
import Foundation

/// ViewModel for Favorites view - displays tracks rated 4/5 or 5/5 stars
/// This is an offline-first hub that pulls data directly from CoreData without server requests
/// Spans all configured servers and libraries
@MainActor
public final class FavoritesViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var tracks: [Track] = []
    @Published public var filterOptions: FilterOptions
    @Published public var favoritesSortOption: FavoritesSortOption = .dateFavorited {
        didSet {
            filterOptions.sortBy = favoritesSortOption.rawValue
        }
    }
    @Published public private(set) var isLoading: Bool = false
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

        setupFilterPersistence()
        setupFilteredTracksPipeline()
        observeDownloadChanges()

        // Initial load
        Task {
            await loadTracks()
        }
    }

    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Favorites") }
            .store(in: &cancellables)
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
                self?.totalDuration = Self.computeTotalDuration(filtered)
            }
            .store(in: &cancellables)
    }

    /// Loads favorite tracks directly from CoreData (offline-first)
    /// Fetches all tracks with rating >= 8 (4+ stars) across all sources
    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            let favoriteTracks = try await libraryRepository.fetchFavoriteTracks()
            tracks = favoriteTracks.map { Track(from: $0) }
        } catch {
            // Silently fail - offline-first means we show what we have
            self.error = error.localizedDescription
            tracks = []
        }

        isLoading = false
    }

    // MARK: - Download Change Observation

    private func observeDownloadChanges() {
        NotificationCenter.default.publisher(for: OfflineDownloadService.downloadsDidChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Filter + Sort (static for background pipeline)

    private static func filterAndSort(_ tracks: [Track], sortOption: FavoritesSortOption, filterOptions: FilterOptions) -> [Track] {
        var filtered = tracks

        if !filterOptions.searchText.isEmpty {
            let searchLower = filterOptions.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }

        if filterOptions.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return sortTracks(filtered, by: sortOption, direction: filterOptions.sortDirection)
    }

    private static func sortTracks(_ tracks: [Track], by sortOption: FavoritesSortOption, direction: SortDirection) -> [Track] {
        let ascending = direction == .ascending
        switch sortOption {
        case .title:
            // Pre-compute sort keys to avoid O(n log n) calls to sortingKey
            return sortByCachedKey(tracks, keyExtractor: { $0.title.sortingKey }, ascending: ascending)
        case .artist:
            return sortByCachedKey(tracks, keyExtractor: { ($0.artistName ?? "").sortingKey }, ascending: ascending)
        case .album:
            return sortByCachedKey(tracks, keyExtractor: { ($0.albumName ?? "").sortingKey }, ascending: ascending)
        case .dateFavorited:
            return tracks.sorted { a, b in
                compareOptionalDates(a.lastRatedAt ?? a.dateAdded, b.lastRatedAt ?? b.dateAdded, ascending: ascending)
            }
        case .duration:
            return tracks.sorted { ascending ? $0.duration < $1.duration : $0.duration > $1.duration }
        case .lastPlayed:
            return tracks.sorted { a, b in
                compareOptionalDates(a.lastPlayed, b.lastPlayed, ascending: ascending)
            }
        case .rating:
            return tracks.sorted { ascending ? $0.rating < $1.rating : $0.rating > $1.rating }
        case .playCount:
            return tracks.sorted { ascending ? $0.playCount < $1.playCount : $0.playCount > $1.playCount }
        }
    }

    /// Sort by pre-computed string keys — computes sortingKey once per element
    private static func sortByCachedKey<T>(_ items: [T], keyExtractor: (T) -> String, ascending: Bool) -> [T] {
        let keyed = items.map { ($0, keyExtractor($0)) }
        return keyed.sorted {
            let result = $0.1.localizedStandardCompare($1.1)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map { $0.0 }
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

    private static func computeTotalDuration(_ tracks: [Track]) -> String {
        let total = tracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(minutes) min"
    }
}
