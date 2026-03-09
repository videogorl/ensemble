import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class ArtistDetailViewModel: ObservableObject {
    @Published public private(set) var artist: Artist
    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    /// Rich metadata loaded on-demand from the single-item metadata endpoint
    @Published public private(set) var artistDetail: ArtistDetail?
    /// Similar artists resolved to local library Artist objects (for navigation)
    @Published public private(set) var resolvedSimilarArtists: [Artist] = []
    /// Whether detail metadata is still loading
    @Published public private(set) var isLoadingDetail = false

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        artist: Artist,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator
    ) {
        self.artist = artist
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.filterOptions = FilterPersistence.load(for: "ArtistDetail")

        // Save filter options when they change
        setupFilterPersistence()

        // Re-fetch tracks when download state changes so offline dimming is accurate
        observeDownloadChanges()
    }

    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "ArtistDetail") }
            .store(in: &cancellables)
    }

    public func loadAlbums() async {
        isLoading = true
        error = nil

        do {
            let cachedAlbums = try await libraryRepository.fetchAlbums(forArtist: artist.id)
            if !cachedAlbums.isEmpty {
                albums = cachedAlbums.map { Album(from: $0) }
            } else if let sourceKey = artist.sourceCompositeKey {
                #if DEBUG
                EnsembleLogger.debug("ArtistDetailViewModel: Albums not found locally, fetching from API for source: \(sourceKey)")
                #endif
                let apiAlbums = try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey)
                albums = apiAlbums
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("ArtistDetailViewModel.loadAlbums error: \(error.localizedDescription)")
            #endif
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func loadTracks() async {
        do {
            let cachedTracks = try await libraryRepository.fetchTracks(forArtist: artist.id)
            if !cachedTracks.isEmpty {
                tracks = cachedTracks.map { Track(from: $0) }
            } else if let sourceKey = artist.sourceCompositeKey {
                #if DEBUG
                EnsembleLogger.debug("ArtistDetailViewModel: Tracks not found locally, fetching from API for source: \(sourceKey)")
                #endif
                let apiTracks = try await syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)
                tracks = apiTracks
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("ArtistDetailViewModel.loadTracks error: \(error.localizedDescription)")
            #endif
            self.error = error.localizedDescription
        }
    }

    /// Loads rich artist metadata (genres, country, similar artists, styles) from the API
    public func loadArtistDetail() async {
        guard let sourceKey = artist.sourceCompositeKey else { return }
        isLoadingDetail = true

        do {
            let detail = try await syncCoordinator.getArtistDetail(artistId: artist.id, sourceKey: sourceKey)
            artistDetail = detail

            // Resolve similar artist names to local library Artist objects
            if let similarNames = detail?.similarArtists, !similarNames.isEmpty {
                await resolveSimilarArtists(names: similarNames)
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("ArtistDetailViewModel.loadArtistDetail error: \(error.localizedDescription)")
            #endif
        }

        isLoadingDetail = false
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

    // MARK: - Similar Artist Resolution

    /// Looks up similar artist names against the local CoreData library
    /// so we can show artwork and enable navigation for artists the user has
    private func resolveSimilarArtists(names: [String]) async {
        var resolved: [Artist] = []
        for name in names {
            do {
                let results = try await libraryRepository.findArtistsByName(name, sourceCompositeKeys: nil)
                // Exact match preferred
                if let exact = results.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    resolved.append(Artist(from: exact))
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("ArtistDetailViewModel: Failed to resolve similar artist '\(name)': \(error.localizedDescription)")
                #endif
            }
        }
        resolvedSimilarArtists = resolved
    }

    // MARK: - Filtered Collections

    /// Filtered albums based on current filter options
    public var filteredAlbums: [Album] {
        applyFilters(to: albums, with: filterOptions)
    }

    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: tracks, with: filterOptions)
    }

    public var totalDuration: String {
        let totalSeconds = filteredTracks.reduce(0) { $0 + $1.duration }
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    public var trackCount: Int {
        filteredTracks.count
    }

    /// Tracks rated 4+ stars (rating >= 8 on 0-10 scale) by this artist
    public var favoritedTracks: [Track] {
        tracks.filter { $0.rating >= 8 }
    }

    // MARK: - Filter Application

    private func applyFilters(to albums: [Album], with options: FilterOptions) -> [Album] {
        var filtered = albums

        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower)
            }
        }

        // Year range filter
        if let yearRange = options.yearRange {
            filtered = filtered.filter {
                guard let year = $0.year else { return false }
                return yearRange.contains(year)
            }
        }

        return filtered
    }

    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks

        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }

        // Downloaded only filter
        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return filtered
    }
}
