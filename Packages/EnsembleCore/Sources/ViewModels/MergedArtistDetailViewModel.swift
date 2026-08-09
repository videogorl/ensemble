import Combine
import EnsemblePersistence
import Foundation

public struct MergedArtistSourceSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let artist: Artist
    public let sourceTitle: String
    public let sourceSubtitle: String
    public let albums: [Album]
    public let tracks: [Track]

    public init(
        artist: Artist,
        sourceTitle: String,
        sourceSubtitle: String,
        albums: [Album],
        tracks: [Track]
    ) {
        self.id = artist.sourceScopedID
        self.artist = artist
        self.sourceTitle = sourceTitle
        self.sourceSubtitle = sourceSubtitle
        self.albums = albums
        self.tracks = tracks
    }
}

@MainActor
public final class MergedArtistDetailViewModel: ObservableObject {
    @Published public private(set) var displayArtist: DisplayArtist
    @Published public private(set) var sourceSections: [MergedArtistSourceSection] = [] {
        didSet { rebuildDisplaySnapshots() }
    }
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions {
        didSet { rebuildDisplaySnapshots() }
    }
    @Published public private(set) var displaySnapshot: ArtistDetailDisplaySnapshot = .empty
    @Published public private(set) var sourceDisplaySnapshots: [String: ArtistDetailDisplaySnapshot] = [:]

    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let accountManager: AccountManager
    private var cancellables = Set<AnyCancellable>()

    public init(
        displayArtist: DisplayArtist,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        accountManager: AccountManager
    ) {
        self.displayArtist = displayArtist
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.accountManager = accountManager
        self.filterOptions = FilterPersistence.load(for: "MergedArtistDetail-\(displayArtist.id)")

        setupFilterPersistence()
        observeReloadTriggers()
    }

    private func setupFilterPersistence() {
        let key = displayArtist.id
        FilterPersistence.observe($filterOptions, key: "MergedArtistDetail-\(key)", storingIn: &cancellables)
    }

    private func observeReloadTriggers() {
        ViewModelNotificationObserver.observeDownloadAndMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        isLoading = true
        error = nil

        do {
            var sections: [MergedArtistSourceSection] = []
            sections.reserveCapacity(displayArtist.artists.count)

            for artist in displayArtist.artists {
                let albums = try await albums(for: artist)
                let tracks = try await tracks(for: artist)
                let sourceDisplay = sourceDisplay(for: artist)
                sections.append(MergedArtistSourceSection(
                    artist: artist,
                    sourceTitle: sourceDisplay.title,
                    sourceSubtitle: sourceDisplay.subtitle,
                    albums: albums,
                    tracks: tracks
                ))
            }

            if sourceSections != sections { sourceSections = sections }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func refreshFromServer() async {
        guard !syncCoordinator.isOffline, !syncCoordinator.isSyncing else {
            await load()
            return
        }

        error = nil
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncAllIncremental()
                continuation.resume()
            }
        }
        await load()
    }

    public var tracks: [Track] {
        sourceSections.flatMap(\.tracks)
    }

    public var albums: [Album] {
        sourceSections.flatMap(\.albums)
    }

    public var filteredAlbums: [Album] {
        displaySnapshot.filteredAlbums
    }

    public var filteredTracks: [Track] {
        displaySnapshot.filteredTracks
    }

    public var trackCount: Int {
        displaySnapshot.trackCount
    }

    public var favoritedTracks: [Track] {
        displaySnapshot.favoritedTracks
    }

    public var availableGenres: [String] {
        displaySnapshot.availableGenres
    }

    public var totalDuration: String {
        MediaFormatters.trackCollectionDuration(displaySnapshot.filteredTracks)
    }

    public func filteredTracks(for section: MergedArtistSourceSection) -> [Track] {
        sourceDisplaySnapshot(for: section).filteredTracks
    }

    public func filteredAlbums(for section: MergedArtistSourceSection) -> [Album] {
        sourceDisplaySnapshot(for: section).filteredAlbums
    }

    public func favoritedTracks(for section: MergedArtistSourceSection) -> [Track] {
        sourceDisplaySnapshot(for: section).favoritedTracks
    }

    public func sourceDisplaySnapshot(for section: MergedArtistSourceSection) -> ArtistDetailDisplaySnapshot {
        sourceDisplaySnapshots[section.id] ?? ArtistDetailDisplaySnapshot(
            albums: section.albums,
            tracks: section.tracks,
            filterOptions: filterOptions
        )
    }

    private func rebuildDisplaySnapshots() {
        let allAlbums = sourceSections.flatMap(\.albums)
        let allTracks = sourceSections.flatMap(\.tracks)
        let nextDisplay = ArtistDetailDisplaySnapshot(albums: allAlbums, tracks: allTracks, filterOptions: filterOptions)
        let nextSourceDisplays = Dictionary(
            uniqueKeysWithValues: sourceSections.map { section in
                (
                    section.id,
                    ArtistDetailDisplaySnapshot(
                        albums: section.albums,
                        tracks: section.tracks,
                        filterOptions: filterOptions
                    )
                )
            }
        )

        if displaySnapshot != nextDisplay {
            displaySnapshot = nextDisplay
        }
        if sourceDisplaySnapshots != nextSourceDisplays {
            sourceDisplaySnapshots = nextSourceDisplays
        }
    }

    private func albums(for artist: Artist) async throws -> [Album] {
        guard let sourceKey = artist.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else { return [] }
        let cached = try await libraryRepository.fetchAlbums(forArtist: artist.id, sourceCompositeKey: sourceKey)
        let localAlbums = ArtistDetailAlbumCollections.sorted(cached.map { Album(from: $0) })
        if !cached.isEmpty {
            if MusicSourceIdentifier(compositeKey: sourceKey)?.type == .appleMusic {
                return localAlbums
            }
            if syncCoordinator.isOffline {
                return localAlbums
            }

            do {
                let remoteAlbums = try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey)
                return ArtistDetailAlbumCollections.merged(local: localAlbums, remote: remoteAlbums)
            } catch {
                EnsembleLogger.debug("MergedArtistDetailViewModel: Artist album supplement failed for \(artist.sourceScopedID): \(error.localizedDescription)")
                return localAlbums
            }
        }
        return ArtistDetailAlbumCollections.sorted(try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey))
    }

    private func tracks(for artist: Artist) async throws -> [Track] {
        guard let sourceKey = artist.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else { return [] }
        let cached = try await libraryRepository.fetchTracks(forArtist: artist.id, sourceCompositeKey: sourceKey)
        if !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        return try await syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)
    }

    private func sourceDisplay(for artist: Artist) -> (title: String, subtitle: String) {
        guard let presentation = accountManager.sourcePresentation(for: artist.sourceCompositeKey) else {
            return ("Unknown Library", "Unknown Source")
        }
        return (
            presentation.libraryName,
            "\(presentation.serverName) · \(presentation.accountName)"
        )
    }
}
