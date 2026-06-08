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
    @Published public private(set) var sourceSections: [MergedArtistSourceSection] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

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
        observeDownloadChanges()
        observeMetadataChanges()
    }

    private func setupFilterPersistence() {
        let key = displayArtist.id
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "MergedArtistDetail-\(key)") }
            .store(in: &cancellables)
    }

    private func observeDownloadChanges() {
        NotificationCenter.default.publisher(for: OfflineDownloadService.downloadsDidChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.load()
                }
            }
            .store(in: &cancellables)
    }

    private func observeMetadataChanges() {
        NotificationCenter.default.publisher(for: MetadataMutationService.metadataDidChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.load()
                }
            }
            .store(in: &cancellables)
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

            sourceSections = sections
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
        MediaFilterEngine.filterAlbums(albums, with: filterOptions, configuration: .artistDetail)
    }

    public var filteredTracks: [Track] {
        MediaFilterEngine.filterTracks(tracks, with: filterOptions, configuration: .artistDetail)
    }

    public var trackCount: Int {
        filteredTracks.count
    }

    public var favoritedTracks: [Track] {
        tracks.filter { $0.rating >= 8 }
    }

    public var availableGenres: [String] {
        LibraryViewModel.extractUniqueGenres(from: tracks.flatMap(\.genres))
    }

    public var totalDuration: String {
        let totalSeconds = filteredTracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(totalSeconds) / 60
        if minutes >= 60 {
            return "\(minutes / 60) hr \(minutes % 60) min"
        }
        return "\(minutes) min"
    }

    public func filteredTracks(for section: MergedArtistSourceSection) -> [Track] {
        MediaFilterEngine.filterTracks(section.tracks, with: filterOptions, configuration: .artistDetail)
    }

    public func filteredAlbums(for section: MergedArtistSourceSection) -> [Album] {
        MediaFilterEngine.filterAlbums(section.albums, with: filterOptions, configuration: .artistDetail)
    }

    public func favoritedTracks(for section: MergedArtistSourceSection) -> [Track] {
        section.tracks.filter { $0.rating >= 8 }
    }

    private func albums(for artist: Artist) async throws -> [Album] {
        if let sourceKey = artist.sourceCompositeKey, !sourceKey.isEmpty {
            let cached = try await libraryRepository.fetchAlbums(forArtist: artist.id, sourceCompositeKey: sourceKey)
            let localAlbums = Self.sortedAlbumsForArtistDetail(cached.map { Album(from: $0) })
            if !cached.isEmpty {
                if syncCoordinator.isOffline {
                    return localAlbums
                }

                do {
                    let remoteAlbums = try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey)
                    return Self.mergedAlbums(local: localAlbums, remote: remoteAlbums)
                } catch {
                    EnsembleLogger.debug("MergedArtistDetailViewModel: Artist album supplement failed for \(artist.sourceScopedID): \(error.localizedDescription)")
                    return localAlbums
                }
            }
            return Self.sortedAlbumsForArtistDetail(try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey))
        }

        return Self.sortedAlbumsForArtistDetail(try await libraryRepository.fetchAlbums(forArtist: artist.id).map { Album(from: $0) })
    }

    private func tracks(for artist: Artist) async throws -> [Track] {
        if let sourceKey = artist.sourceCompositeKey, !sourceKey.isEmpty {
            let cached = try await libraryRepository.fetchTracks(forArtist: artist.id, sourceCompositeKey: sourceKey)
            if !cached.isEmpty {
                return cached.map { Track(from: $0) }
            }
            return try await syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)
        }

        return try await libraryRepository.fetchTracks(forArtist: artist.id).map { Track(from: $0) }
    }

    private func sourceDisplay(for artist: Artist) -> (title: String, subtitle: String) {
        guard let context = accountManager.sourceLibraryContext(for: artist.sourceCompositeKey) else {
            return ("Unknown Library", "Unknown Source")
        }
        return (context.libraryTitle, "\(context.serverName) · \(context.accountName)")
    }

    private static func mergedAlbums(local: [Album], remote: [Album]) -> [Album] {
        guard !remote.isEmpty else { return sortedAlbumsForArtistDetail(local) }
        var albumsByID = Dictionary(uniqueKeysWithValues: local.map { ($0.sourceScopedID, $0) })
        for album in remote where album.releaseFormat != nil || albumsByID[album.sourceScopedID] == nil {
            albumsByID[album.sourceScopedID] = album
        }
        return sortedAlbumsForArtistDetail(Array(albumsByID.values))
    }

    private static func sortedAlbumsForArtistDetail(_ albums: [Album]) -> [Album] {
        albums.sorted { left, right in
            let leftYear = left.year ?? Int.min
            let rightYear = right.year ?? Int.min
            if leftYear != rightYear {
                return leftYear > rightYear
            }
            let titleComparison = left.title.localizedStandardCompare(right.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return left.sourceScopedID < right.sourceScopedID
        }
    }
}
