import Combine
import EnsemblePersistence
import Foundation

// MARK: - Protocol

@MainActor
public protocol MediaDetailViewModelProtocol: ObservableObject {
    var tracks: [Track] { get }
    var filteredTracks: [Track] { get }
    var isLoading: Bool { get }
    var hasLoadedTracks: Bool { get }
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
    @Published public private(set) var hasLoadedTracks = false
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
    private let hiddenMediaStore: HiddenMediaStore
    private let includesHidden: Bool
    private var cancellables = Set<AnyCancellable>()

    public init(
        album: Album,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        initialTracks: [Track]? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        includesHidden: Bool = false
    ) {
        let hiddenMediaStore = hiddenMediaStore ?? .shared
        self.album = album
        if let initialTracks {
            self.tracks = includesHidden ? initialTracks : hiddenMediaStore.snapshot.visibleTracks(initialTracks)
            self.hasLoadedTracks = true
        }
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.hiddenMediaStore = hiddenMediaStore
        self.includesHidden = includesHidden
        self.filterOptions = FilterPersistence.load(for: "AlbumDetail")
        
        // Save filter options when they change
        setupFilterPersistence()

        // Re-fetch tracks when download state changes so offline dimming is accurate
        observeDownloadChanges()
        observeMetadataChanges()
        hiddenMediaStore.$snapshot.dropFirst().sink { [weak self] _ in
            Task { await self?.loadTracks() }
        }.store(in: &cancellables)
    }
    
    private func setupFilterPersistence() {
        FilterPersistence.observe($filterOptions, key: "AlbumDetail", storingIn: &cancellables)
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        guard let sourceKey = album.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else {
            if !tracks.isEmpty { tracks = [] }
            hasLoadedTracks = true
            isLoading = false
            return
        }

        do {
            // First try to fetch from local repository
            let cachedTracks = try await libraryRepository.fetchTracks(
                forAlbum: album.id,
                sourceCompositeKey: sourceKey
            )

            if !cachedTracks.isEmpty {
                let loaded = cachedTracks.map { Track(from: $0) }
                let mapped = includesHidden ? loaded : hiddenMediaStore.snapshot.visibleTracks(loaded)
                // Diagnostic: detect "Unknown Track" entries to trace empty-title source
                let unknownCount = mapped.lazy.filter { $0.title == "Unknown Track" }.count
                if unknownCount > 0 {
                    EnsembleLogger.debug("AlbumDetailViewModel.loadTracks: \(unknownCount)/\(mapped.count) tracks have 'Unknown Track' title for album \(album.id)")
                }
                if tracks != mapped { tracks = mapped }
            } else {
                // If not found and we have a source key, try to fetch from API
                EnsembleLogger.debug("AlbumDetailViewModel: Tracks not found locally, fetching from API for source: \(sourceKey)")
                let loaded = try await syncCoordinator.getAlbumTracks(albumId: album.id, sourceKey: sourceKey)
                let apiTracks = includesHidden ? loaded : hiddenMediaStore.snapshot.visibleTracks(loaded)
                if tracks != apiTracks { tracks = apiTracks }
            }
        } catch {
            EnsembleLogger.debug("AlbumDetailViewModel error: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }

        hasLoadedTracks = true
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
            EnsembleLogger.debug("AlbumDetailViewModel.loadAlbumDetail error: \(error.localizedDescription)")
        }

        isLoadingDetail = false
    }

    /// Loads albums by the same artist, excluding the current album.
    /// First tries CoreData, falls back to API if empty (same pattern as ArtistDetailViewModel.loadAlbums).
    public func loadRelatedAlbums() async {
        guard let artistId = album.artistRatingKey,
              let sourceKey = album.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else {
            if !relatedAlbums.isEmpty { relatedAlbums = [] }
            return
        }

        do {
            let cachedAlbums = try await libraryRepository.fetchAlbums(
                forArtist: artistId,
                sourceCompositeKey: sourceKey
            )
            if !cachedAlbums.isEmpty {
                let nextAlbums = cachedAlbums
                    .map { Album(from: $0) }
                    .filter { $0.sourceScopedID != album.sourceScopedID }
                if relatedAlbums != nextAlbums { relatedAlbums = nextAlbums }
            } else {
                // Fallback to API if not found locally
                EnsembleLogger.debug("AlbumDetailViewModel: Related albums not found locally, fetching from API")
                let apiAlbums = try await syncCoordinator.getArtistAlbums(artistId: artistId, sourceKey: sourceKey)
                let nextAlbums = apiAlbums.filter { $0.id != album.id }
                if relatedAlbums != nextAlbums { relatedAlbums = nextAlbums }
            }
        } catch {
            EnsembleLogger.debug("AlbumDetailViewModel.loadRelatedAlbums error: \(error.localizedDescription)")
        }
    }

    /// Loads similar/related albums from Plex's recommendation engine
    public func loadSimilarAlbums() async {
        guard let sourceKey = album.sourceCompositeKey else { return }

        do {
            let albums = try await syncCoordinator.getSimilarAlbums(albumId: album.id, sourceKey: sourceKey)
            let nextAlbums = albums.filter { $0.id != album.id }
            if similarAlbums != nextAlbums { similarAlbums = nextAlbums }
        } catch {
            EnsembleLogger.debug("AlbumDetailViewModel.loadSimilarAlbums error: \(error.localizedDescription)")
        }
    }

    // MARK: - Download Change Observation

    private func observeDownloadChanges() {
        ViewModelNotificationObserver.observeDownloadChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
        }
    }

    private func observeMetadataChanges() {
        ViewModelNotificationObserver.observeMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
            await self?.loadRelatedAlbums()
        }
    }

    // MARK: - Filtered Collections
    
    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: tracks, with: filterOptions)
    }

    public var totalDuration: String {
        MediaFormatters.trackCollectionDuration(filteredTracks)
    }
    
    // MARK: - Filter Application
    
    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        MediaFilterEngine.filterTracks(tracks, with: options, configuration: .albumDetail)
    }
}
