import AsyncAlgorithms
import Combine
import EnsemblePersistence
import EnsembleSupport
import Foundation
import Observation

// MARK: - Protocol

@MainActor
public protocol MediaDetailViewModelProtocol: AnyObject, Observable {
    var tracks: [Track] { get }
    var filteredTracks: [Track] { get }
    var isLoading: Bool { get }
    var hasLoadedTracks: Bool { get }
    var error: String? { get }
    var totalDuration: String { get }
    var filterOptions: FilterOptions { get set }
    
    func loadTracks() async
    /// Starts the model's change observation. Safe to call on every appearance.
    func start()
    var playableTracks: [Track] { get }
    func mutationCandidates(for track: Track) -> [Track]
}

public extension MediaDetailViewModelProtocol {
    var playableTracks: [Track] {
        filteredTracks.filter(\.isLibraryAvailable)
    }

    func playbackSelection(for track: Track) -> (tracks: [Track], index: Int)? {
        guard track.isLibraryAvailable else { return nil }
        let tracks = playableTracks
        guard let index = tracks.firstIndex(where: { $0.playbackIdentity == track.playbackIdentity }) else {
            return nil
        }
        return (tracks, index)
    }

    func mutationCandidates(for track: Track) -> [Track] { [track] }
}

// MARK: - Album Detail ViewModel

@MainActor
@Observable
public final class AlbumDetailViewModel: MediaDetailViewModelProtocol {
    public let displayAlbum: DisplayAlbum
    public private(set) var album: Album
    public private(set) var tracks: [Track] = []
    public private(set) var isLoading = false
    public private(set) var hasLoadedTracks = false
    public private(set) var error: String?
    public var filterOptions: FilterOptions {
        didSet { FilterPersistence.save(filterOptions, for: "AlbumDetail") }
    }

    /// Rich metadata loaded on-demand from the single-item metadata endpoint
    public private(set) var albumDetail: AlbumDetail?
    /// Albums by the same artist, excluding the current album
    public private(set) var relatedAlbums: [Album] = []
    /// Similar/related albums from Plex's recommendation engine
    public private(set) var similarAlbums: [Album] = []
    /// Whether detail metadata is still loading
    public private(set) var isLoadingDetail = false

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let hiddenMediaStore: HiddenMediaStore
    private let settingsManager: SettingsManager
    private let includesHidden: Bool
    private var sourceTracks: [Track] = []
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var subscriptions: [StreamSubscription] = []

    @ObservationIgnored private let libraryChanges: LibraryChanges?

    public init(
        displayAlbum: DisplayAlbum,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        initialTracks: [Track]? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        settingsManager: SettingsManager? = nil,
        includesHidden: Bool = false,
        libraryChanges: LibraryChanges? = nil
    ) {
        self.libraryChanges = libraryChanges
        let hiddenMediaStore = hiddenMediaStore ?? .shared
        self.displayAlbum = displayAlbum
        self.album = displayAlbum.primaryAlbum
        self.settingsManager = settingsManager ?? SettingsManager()
        if let initialTracks {
            let visible = includesHidden ? initialTracks : hiddenMediaStore.snapshot.visibleTracks(initialTracks)
            self.sourceTracks = visible
            self.tracks = MergingProjection.albumTracks(visible, preferences: self.settingsManager.mergingPreferences)
            self.hasLoadedTracks = true
        }
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.hiddenMediaStore = hiddenMediaStore
        self.includesHidden = includesHidden
        self.filterOptions = FilterPersistence.load(for: "AlbumDetail")
    }

    /// Starts reloading on download, metadata, hidden-media, and merging
    /// changes. Safe to call on every appearance.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // Re-fetch tracks when download state changes so offline dimming is accurate
        observeDownloadChanges()
        observeMetadataChanges()
        subscriptions.append(hiddenMediaStore.snapshots().dropFirst().observe(self) { model, _ in
            Task { await model.loadTracks() }
        })
        subscriptions.append(settingsManager.snapshots().map(\.mergingPreferences).removeDuplicates().dropFirst().observe(self) { model, preferences in
            let projected = MergingProjection.albumTracks(model.sourceTracks, preferences: preferences)
            if model.tracks != projected { model.tracks = projected }
        })
    }

    public convenience init(
        album: Album,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        initialTracks: [Track]? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        settingsManager: SettingsManager? = nil,
        includesHidden: Bool = false
    ) {
        self.init(
            displayAlbum: .single(album),
            libraryRepository: libraryRepository,
            syncCoordinator: syncCoordinator,
            initialTracks: initialTracks,
            hiddenMediaStore: hiddenMediaStore,
            settingsManager: settingsManager,
            includesHidden: includesHidden
        )
    }
    
    public func loadTracks() async {
        isLoading = true
        error = nil

        var loadedTracks: [Track] = []
        var lastError: Error?
        for sourceAlbum in displayAlbum.albums {
            do {
                loadedTracks.append(contentsOf: try await sourceAlbum.resolvedTracks(using: libraryRepository, syncCoordinator: syncCoordinator))
            } catch {
                lastError = error
                EnsembleLogger.debug("AlbumDetailViewModel error for \(sourceAlbum.sourceScopedID): \(error.localizedDescription)")
            }
        }

        let visible = includesHidden ? loadedTracks : hiddenMediaStore.snapshot.visibleTracks(loadedTracks)
        sourceTracks = visible
        let projected = MergingProjection.albumTracks(visible, preferences: settingsManager.mergingPreferences)
        if tracks != projected { tracks = projected }
        if loadedTracks.isEmpty, let lastError {
            self.error = lastError.localizedDescription
        }

        hasLoadedTracks = true
        isLoading = false
    }

    public func displayedTrackIdentity(for selectedTrackId: String?) -> String? {
        guard let selectedTrackId else { return nil }
        if tracks.contains(where: { $0.playbackIdentity == selectedTrackId }) { return selectedTrackId }
        guard settingsManager.mergingPreferences.isEnabled,
              settingsManager.mergingPreferences.mergeTracks,
              let source = sourceTracks.first(where: { $0.playbackIdentity == selectedTrackId }),
              let identity = MergingProjection.trackIdentity(source) else { return selectedTrackId }
        return tracks.first { MergingProjection.trackIdentity($0) == identity }?.playbackIdentity ?? selectedTrackId
    }

    public func mutationCandidates(for track: Track) -> [Track] {
        MergingProjection.mutationCandidates(
            for: track,
            in: sourceTracks,
            preferences: settingsManager.mergingPreferences
        )
    }

    public func filteredTracks(for album: Album) -> [Track] {
        applyFilters(
            to: sourceTracks.filter {
                $0.albumRatingKey == album.id &&
                    $0.sourceCompositeKey == album.sourceCompositeKey
            },
            with: filterOptions
        )
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
        subscriptions += ViewModelChangeObserver.observeDownloadChanges(from: libraryChanges, for: self) { model in
            await model.loadTracks()
        }
    }

    private func observeMetadataChanges() {
        subscriptions += ViewModelChangeObserver.observeMetadataChanges(from: libraryChanges, for: self) { model in
            await model.loadTracks()
            await model.loadRelatedAlbums()
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
