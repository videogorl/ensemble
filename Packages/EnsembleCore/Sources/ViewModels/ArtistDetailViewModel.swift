import Combine
import EnsemblePersistence
import Foundation

public struct ArtistDetailDisplaySnapshot: Equatable, Sendable {
    public let filteredAlbums: [Album]
    public let studioAlbums: [Album]
    public let singlesAndEPs: [Album]
    public let filteredTracks: [Track]
    public let favoritedTracks: [Track]
    public let availableGenres: [String]
    public let trackCount: Int

    public static let empty = ArtistDetailDisplaySnapshot(albums: [], tracks: [], filterOptions: FilterOptions())

    public init(albums: [Album], tracks: [Track], filterOptions: FilterOptions) {
        let filteredAlbums = MediaFilterEngine.filterAlbums(albums, with: filterOptions, configuration: .artistDetail)
        let filteredTracks = MediaFilterEngine.filterTracks(tracks, with: filterOptions, configuration: .artistDetail)

        self.filteredAlbums = filteredAlbums
        self.studioAlbums = filteredAlbums.filter { !$0.isLikelySingleOrEP() }
        self.singlesAndEPs = filteredAlbums.filter { $0.isLikelySingleOrEP() }
        self.filteredTracks = filteredTracks
        self.favoritedTracks = tracks.filter { $0.rating >= 8 }
        self.availableGenres = Self.extractUniqueGenres(from: tracks.flatMap(\.genres))
        self.trackCount = filteredTracks.count
    }

    private static func extractUniqueGenres(from names: [String]) -> [String] {
        let filtered = names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(Set(filtered)).sorted()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filteredAlbums == rhs.filteredAlbums &&
            sourceScopedIDs(lhs.filteredAlbums) == sourceScopedIDs(rhs.filteredAlbums) &&
            sourceScopedIDs(lhs.studioAlbums) == sourceScopedIDs(rhs.studioAlbums) &&
            sourceScopedIDs(lhs.singlesAndEPs) == sourceScopedIDs(rhs.singlesAndEPs) &&
            lhs.filteredTracks == rhs.filteredTracks &&
            sourceScopedIDs(lhs.filteredTracks) == sourceScopedIDs(rhs.filteredTracks) &&
            lhs.favoritedTracks == rhs.favoritedTracks &&
            sourceScopedIDs(lhs.favoritedTracks) == sourceScopedIDs(rhs.favoritedTracks) &&
            lhs.availableGenres == rhs.availableGenres &&
            lhs.trackCount == rhs.trackCount
    }

    private static func sourceScopedIDs(_ albums: [Album]) -> [String] {
        albums.map(\.sourceScopedID)
    }

    private static func sourceScopedIDs(_ tracks: [Track]) -> [String] {
        tracks.map(\.sourceScopedID)
    }
}

@MainActor
public final class ArtistDetailViewModel: ObservableObject {
    @Published public private(set) var artist: Artist
    @Published public private(set) var albums: [Album] = [] {
        didSet { rebuildDisplaySnapshot() }
    }
    @Published public private(set) var tracks: [Track] = [] {
        didSet { rebuildDisplaySnapshot() }
    }
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions {
        didSet { rebuildDisplaySnapshot() }
    }
    @Published public private(set) var displaySnapshot: ArtistDetailDisplaySnapshot = .empty

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
        observeMetadataChanges()
    }

    private func setupFilterPersistence() {
        FilterPersistence.observe($filterOptions, key: "ArtistDetail", storingIn: &cancellables)
    }

    public func loadAlbums() async {
        isLoading = true
        error = nil

        do {
            let cachedAlbums: [CDAlbum]
            if let sourceKey = artist.sourceCompositeKey, !sourceKey.isEmpty {
                cachedAlbums = try await libraryRepository.fetchAlbums(forArtist: artist.id, sourceCompositeKey: sourceKey)
            } else {
                cachedAlbums = try await libraryRepository.fetchAlbums(forArtist: artist.id)
            }
            if !cachedAlbums.isEmpty {
                albums = ArtistDetailAlbumCollections.sorted(cachedAlbums.map { Album(from: $0) })
            }

            if let sourceKey = artist.sourceCompositeKey, !syncCoordinator.isOffline {
                EnsembleLogger.debug("ArtistDetailViewModel: Refreshing artist albums from API for source: \(sourceKey)")
                do {
                    let apiAlbums = try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey)
                    let mergedAlbums = ArtistDetailAlbumCollections.merged(local: albums, remote: apiAlbums)
                    if mergedAlbums != albums {
                        albums = mergedAlbums
                    }
                } catch {
                    if albums.isEmpty {
                        throw error
                    }
                    EnsembleLogger.debug("ArtistDetailViewModel: Artist album supplement failed for \(artist.sourceScopedID): \(error.localizedDescription)")
                }
            }
        } catch {
            EnsembleLogger.debug("ArtistDetailViewModel.loadAlbums error: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func loadTracks() async {
        do {
            let cachedTracks: [CDTrack]
            if let sourceKey = artist.sourceCompositeKey, !sourceKey.isEmpty {
                cachedTracks = try await libraryRepository.fetchTracks(forArtist: artist.id, sourceCompositeKey: sourceKey)
            } else {
                cachedTracks = try await libraryRepository.fetchTracks(forArtist: artist.id)
            }
            if !cachedTracks.isEmpty {
                tracks = cachedTracks.map { Track(from: $0) }
            } else if let sourceKey = artist.sourceCompositeKey {
                EnsembleLogger.debug("ArtistDetailViewModel: Tracks not found locally, fetching from API for source: \(sourceKey)")
                let apiTracks = try await syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)
                tracks = apiTracks
            }
        } catch {
            EnsembleLogger.debug("ArtistDetailViewModel.loadTracks error: \(error.localizedDescription)")
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
            EnsembleLogger.debug("ArtistDetailViewModel.loadArtistDetail error: \(error.localizedDescription)")
        }

        isLoadingDetail = false
    }

    // MARK: - Download Change Observation

    private func observeDownloadChanges() {
        ViewModelNotificationObserver.observeDownloadChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
        }
    }

    private func observeMetadataChanges() {
        ViewModelNotificationObserver.observeMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadAlbums()
            await self?.loadTracks()
        }
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
                EnsembleLogger.debug("ArtistDetailViewModel: Failed to resolve similar artist '\(name)': \(error.localizedDescription)")
            }
        }
        resolvedSimilarArtists = resolved
    }

    // MARK: - Filtered Collections

    /// Filtered albums based on current filter options
    public var filteredAlbums: [Album] {
        displaySnapshot.filteredAlbums
    }

    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        displaySnapshot.filteredTracks
    }

    public var totalDuration: String {
        MediaFormatters.trackCollectionDuration(displaySnapshot.filteredTracks)
    }

    public var trackCount: Int {
        displaySnapshot.trackCount
    }

    /// Tracks rated 4+ stars (rating >= 8 on 0-10 scale) by this artist
    public var favoritedTracks: [Track] {
        displaySnapshot.favoritedTracks
    }

    private func rebuildDisplaySnapshot() {
        let next = ArtistDetailDisplaySnapshot(albums: albums, tracks: tracks, filterOptions: filterOptions)
        if displaySnapshot != next {
            displaySnapshot = next
        }
    }
}
