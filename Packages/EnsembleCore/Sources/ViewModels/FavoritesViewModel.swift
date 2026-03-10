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
    @Published public var favoritesSortOption: FavoritesSortOption = .dateAdded {
        didSet {
            filterOptions.sortBy = favoritesSortOption.rawValue
        }
    }
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: String?

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

    public var filteredTracks: [Track] {
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

        return sortTracks(filtered)
    }

    // MARK: - Sorting

    private func sortTracks(_ tracks: [Track]) -> [Track] {
        let ascending = filterOptions.sortDirection == .ascending
        return tracks.sorted { a, b in
            switch favoritesSortOption {
            case .title:
                let result = a.title.sortingKey.localizedStandardCompare(b.title.sortingKey)
                return ascending ? result == .orderedAscending : result == .orderedDescending

            case .artist:
                let aName = a.artistName ?? ""
                let bName = b.artistName ?? ""
                let result = aName.sortingKey.localizedStandardCompare(bName.sortingKey)
                return ascending ? result == .orderedAscending : result == .orderedDescending

            case .album:
                let aName = a.albumName ?? ""
                let bName = b.albumName ?? ""
                let result = aName.sortingKey.localizedStandardCompare(bName.sortingKey)
                return ascending ? result == .orderedAscending : result == .orderedDescending

            case .dateAdded:
                return compareOptionalDates(a.dateAdded, b.dateAdded, ascending: ascending)

            case .duration:
                return ascending ? a.duration < b.duration : a.duration > b.duration

            case .lastPlayed:
                return compareOptionalDates(a.lastPlayed, b.lastPlayed, ascending: ascending)

            case .rating:
                return ascending ? a.rating < b.rating : a.rating > b.rating

            case .playCount:
                return ascending ? a.playCount < b.playCount : a.playCount > b.playCount
            }
        }
    }

    /// Compares optional dates with nils sorting last regardless of direction
    private func compareOptionalDates(_ a: Date?, _ b: Date?, ascending: Bool) -> Bool {
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

    public var totalDuration: String {
        let total = filteredTracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(minutes) min"
    }
}
