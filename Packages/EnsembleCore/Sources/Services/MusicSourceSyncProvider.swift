import EnsemblePersistence
import EnsembleAPI
import Foundation

public struct LibrarySyncResult: Sendable, Equatable {
    public let changedArtists: Int
    public let changedAlbums: Int
    public let changedTracks: Int
    public let changedGenres: Int
    public let removedArtists: Int
    public let removedAlbums: Int
    public let removedTracks: Int
    public let removedGenres: Int

    public init(
        changedArtists: Int = 0,
        changedAlbums: Int = 0,
        changedTracks: Int = 0,
        changedGenres: Int = 0,
        removedArtists: Int = 0,
        removedAlbums: Int = 0,
        removedTracks: Int = 0,
        removedGenres: Int = 0
    ) {
        self.changedArtists = changedArtists
        self.changedAlbums = changedAlbums
        self.changedTracks = changedTracks
        self.changedGenres = changedGenres
        self.removedArtists = removedArtists
        self.removedAlbums = removedAlbums
        self.removedTracks = removedTracks
        self.removedGenres = removedGenres
    }

    public var hasMaterialChanges: Bool {
        changedArtists > 0 || changedAlbums > 0 || changedTracks > 0 || changedGenres > 0 ||
        removedArtists > 0 || removedAlbums > 0 || removedTracks > 0 || removedGenres > 0
    }
}

public struct PlaylistSyncResult: Sendable, Equatable {
    public let changedPlaylists: Int
    public let removedPlaylists: Int

    public init(changedPlaylists: Int = 0, removedPlaylists: Int = 0) {
        self.changedPlaylists = changedPlaylists
        self.removedPlaylists = removedPlaylists
    }

    public var hasMaterialChanges: Bool {
        changedPlaylists > 0 || removedPlaylists > 0
    }
}

/// Protocol for syncing music from a source (Plex, future Apple Music, etc.)
public protocol MusicSourceSyncProvider: Sendable {
    var sourceIdentifier: MusicSourceIdentifier { get }

    /// Sync the library content (artists, albums, tracks, genres) to CoreData
    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult
    
    /// Sync only items added or updated since the given timestamp (incremental sync)
    /// - Parameter since: Unix timestamp of last sync (fetch items added/updated after this)
    func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult
    
    /// Sync playlists to CoreData (should be called once per server, not per library)
    func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult

    /// Sync only playlists added or updated since last sync (incremental)
    func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult

    /// Get a streaming resolution for a track — may be a direct URL, downloaded file,
    /// or progressive transcode config for chunked streaming.
    func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution

    /// Get an artwork URL
    func getArtworkURL(path: String?, size: Int) async throws -> URL?

    /// Rate a track (0-10)
    func rateTrack(ratingKey: String, rating: Int?) async throws

    /// Report playback timeline to the server
    func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws

    /// Scrobble a track (mark as played)
    func scrobble(ratingKey: String) async throws

    /// Get tracks for an album directly from the source
    func getAlbumTracks(albumKey: String) async throws -> [Track]

    /// Get albums for an artist directly from the source
    func getArtistAlbums(artistKey: String) async throws -> [Album]

    /// Get all tracks for an artist directly from the source
    func getArtistTracks(artistKey: String) async throws -> [Track]

    /// Get detailed artist metadata (genres, country, similar artists, styles)
    func getArtistDetail(artistKey: String) async throws -> ArtistDetail?

    /// Get detailed album metadata (genres, styles, studio/label)
    func getAlbumDetail(albumKey: String) async throws -> AlbumDetail?

    /// Get similar/related albums from Plex's recommendation engine
    func getSimilarAlbums(albumKey: String) async throws -> [Album]
}

extension MusicSourceSyncProvider {
    public func getArtistDetail(artistKey: String) async throws -> ArtistDetail? { nil }
    public func getAlbumDetail(albumKey: String) async throws -> AlbumDetail? { nil }
    public func getSimilarAlbums(albumKey: String) async throws -> [Album] { [] }
}
