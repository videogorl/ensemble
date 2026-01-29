import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

public protocol LibrarySyncServiceProtocol {
    var isSyncing: Bool { get }
    var syncProgress: Double { get }
    var isSyncingPublisher: AnyPublisher<Bool, Never> { get }
    var syncProgressPublisher: AnyPublisher<Double, Never> { get }

    func syncLibrary() async throws
    func syncArtists(sectionKey: String) async throws
    func syncAlbums(sectionKey: String) async throws
    func syncTracks(sectionKey: String) async throws
    func syncGenres(sectionKey: String) async throws
    func syncPlaylists() async throws
}

public final class LibrarySyncService: LibrarySyncServiceProtocol {
    @Published public private(set) var isSyncing = false
    @Published public private(set) var syncProgress: Double = 0

    public var isSyncingPublisher: AnyPublisher<Bool, Never> { $isSyncing.eraseToAnyPublisher() }
    public var syncProgressPublisher: AnyPublisher<Double, Never> { $syncProgress.eraseToAnyPublisher() }

    private let apiClient: PlexAPIClient
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol

    public init(
        apiClient: PlexAPIClient,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.apiClient = apiClient
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
    }

    public func syncLibrary() async throws {
        guard !isSyncing else { return }

        await MainActor.run {
            isSyncing = true
            syncProgress = 0
        }

        defer {
            Task { @MainActor in
                isSyncing = false
                syncProgress = 1.0
            }
        }

        // Find music library section
        guard let musicSection = try await apiClient.getMusicLibrarySection() else {
            throw NSError(domain: "LibrarySyncService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No music library found"])
        }

        let sectionKey = musicSection.key

        // Sync in stages
        await MainActor.run { syncProgress = 0.1 }
        try await syncArtists(sectionKey: sectionKey)

        await MainActor.run { syncProgress = 0.3 }
        try await syncAlbums(sectionKey: sectionKey)

        await MainActor.run { syncProgress = 0.5 }
        try await syncTracks(sectionKey: sectionKey)

        await MainActor.run { syncProgress = 0.7 }
        try await syncGenres(sectionKey: sectionKey)

        await MainActor.run { syncProgress = 0.9 }
        try await syncPlaylists()
    }

    public func syncArtists(sectionKey: String) async throws {
        let artists = try await apiClient.getArtists(sectionKey: sectionKey)

        for artist in artists {
            _ = try await libraryRepository.upsertArtist(
                ratingKey: artist.ratingKey,
                key: artist.key,
                name: artist.title,
                summary: artist.summary,
                thumbPath: artist.thumb,
                artPath: artist.art
            )
        }
    }

    public func syncAlbums(sectionKey: String) async throws {
        let albums = try await apiClient.getAlbums(sectionKey: sectionKey)

        for album in albums {
            _ = try await libraryRepository.upsertAlbum(
                ratingKey: album.ratingKey,
                key: album.key,
                title: album.title,
                artistName: album.parentTitle,
                artistRatingKey: album.parentRatingKey,
                summary: album.summary,
                thumbPath: album.thumb,
                artPath: album.art,
                year: album.year,
                trackCount: album.leafCount
            )
        }
    }

    public func syncTracks(sectionKey: String) async throws {
        let tracks = try await apiClient.getTracks(sectionKey: sectionKey)

        for track in tracks {
            _ = try await libraryRepository.upsertTrack(
                ratingKey: track.ratingKey,
                key: track.key,
                title: track.title,
                artistName: track.grandparentTitle,
                albumName: track.parentTitle,
                albumRatingKey: track.parentRatingKey,
                trackNumber: track.index,
                discNumber: track.parentIndex,
                duration: track.duration,
                thumbPath: track.thumb ?? track.parentThumb,
                streamKey: track.streamURL
            )
        }
    }

    public func syncGenres(sectionKey: String) async throws {
        let genres = try await apiClient.getGenres(sectionKey: sectionKey)

        for genre in genres {
            _ = try await libraryRepository.upsertGenre(
                ratingKey: genre.ratingKey,
                key: genre.key,
                title: genre.title
            )
        }
    }

    public func syncPlaylists() async throws {
        let playlists = try await apiClient.getPlaylists()

        for playlist in playlists {
            let savedPlaylist = try await playlistRepository.upsertPlaylist(
                ratingKey: playlist.ratingKey,
                key: playlist.key,
                title: playlist.title,
                summary: playlist.summary,
                compositePath: playlist.composite,
                isSmart: playlist.smart ?? false,
                duration: playlist.duration,
                trackCount: playlist.leafCount
            )

            // Sync playlist tracks
            let tracks = try await apiClient.getPlaylistTracks(playlistKey: playlist.ratingKey)
            let trackKeys = tracks.map { $0.ratingKey }
            try await playlistRepository.setPlaylistTracks(trackKeys, forPlaylist: savedPlaylist.ratingKey)
        }
    }
}
