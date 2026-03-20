import Combine
import EnsemblePersistence
import Foundation

// MARK: - Protocol

@MainActor
public protocol MediaDetailViewModelProtocol: ObservableObject {
    var tracks: [Track] { get }
    var filteredTracks: [Track] { get }
    var isLoading: Bool { get }
    var error: String? { get }
    var totalDuration: String { get }
    var filterOptions: FilterOptions { get set }
    
    func loadTracks() async
}

// MARK: - Album Detail ViewModel

@MainActor
public final class AlbumDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var album: Album
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    /// Rich metadata loaded on-demand from the single-item metadata endpoint
    @Published public private(set) var albumDetail: AlbumDetail?
    /// Albums by the same artist, excluding the current album
    @Published public private(set) var relatedAlbums: [Album] = []
    /// Similar/related albums from Plex's recommendation engine
    @Published public private(set) var similarAlbums: [Album] = []
    /// Whether detail metadata is still loading
    @Published public private(set) var isLoadingDetail = false

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        album: Album,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator
    ) {
        self.album = album
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.filterOptions = FilterPersistence.load(for: "AlbumDetail")
        
        // Save filter options when they change
        setupFilterPersistence()

        // Re-fetch tracks when download state changes so offline dimming is accurate
        observeDownloadChanges()
    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "AlbumDetail") }
            .store(in: &cancellables)
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            // First try to fetch from local repository
            let cachedTracks = try await libraryRepository.fetchTracks(forAlbum: album.id)
            
            if !cachedTracks.isEmpty {
                tracks = cachedTracks.map { Track(from: $0) }
            } else if let sourceKey = album.sourceCompositeKey {
                // If not found and we have a source key, try to fetch from API
                #if DEBUG
                EnsembleLogger.debug("💿 AlbumDetailViewModel: Tracks not found locally, fetching from API for source: \(sourceKey)")
                #endif
                let apiTracks = try await syncCoordinator.getAlbumTracks(albumId: album.id, sourceKey: sourceKey)
                tracks = apiTracks
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ AlbumDetailViewModel error: \(error.localizedDescription)")
            #endif
            self.error = error.localizedDescription
        }

        isLoading = false
    }
    
    /// Loads rich album metadata (genres, styles, studio/label) from the API
    public func loadAlbumDetail() async {
        guard let sourceKey = album.sourceCompositeKey else { return }
        isLoadingDetail = true

        do {
            let detail = try await syncCoordinator.getAlbumDetail(albumId: album.id, sourceKey: sourceKey)
            albumDetail = detail
        } catch {
            #if DEBUG
            EnsembleLogger.debug("AlbumDetailViewModel.loadAlbumDetail error: \(error.localizedDescription)")
            #endif
        }

        isLoadingDetail = false
    }

    /// Loads albums by the same artist, excluding the current album.
    /// First tries CoreData, falls back to API if empty (same pattern as ArtistDetailViewModel.loadAlbums).
    public func loadRelatedAlbums() async {
        guard let artistId = album.artistRatingKey else { return }

        do {
            let cachedAlbums = try await libraryRepository.fetchAlbums(forArtist: artistId)
            if !cachedAlbums.isEmpty {
                relatedAlbums = cachedAlbums
                    .map { Album(from: $0) }
                    .filter { $0.id != album.id }
            } else if let sourceKey = album.sourceCompositeKey {
                // Fallback to API if not found locally
                #if DEBUG
                EnsembleLogger.debug("AlbumDetailViewModel: Related albums not found locally, fetching from API")
                #endif
                let apiAlbums = try await syncCoordinator.getArtistAlbums(artistId: artistId, sourceKey: sourceKey)
                relatedAlbums = apiAlbums.filter { $0.id != album.id }
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("AlbumDetailViewModel.loadRelatedAlbums error: \(error.localizedDescription)")
            #endif
        }
    }

    /// Loads similar/related albums from Plex's recommendation engine
    public func loadSimilarAlbums() async {
        guard let sourceKey = album.sourceCompositeKey else { return }

        do {
            let albums = try await syncCoordinator.getSimilarAlbums(albumId: album.id, sourceKey: sourceKey)
            similarAlbums = albums.filter { $0.id != album.id }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("AlbumDetailViewModel.loadSimilarAlbums error: \(error.localizedDescription)")
            #endif
        }
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

    // MARK: - Filtered Collections
    
    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: tracks, with: filterOptions)
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
    
    // MARK: - Filter Application
    
    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks
        
        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false)
            }
        }
        
        // Downloaded only filter
        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }
        
        return filtered
    }
}
