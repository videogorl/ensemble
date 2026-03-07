import EnsemblePersistence
import EnsembleAPI
import Foundation

/// Protocol for syncing music from a source (Plex, future Apple Music, etc.)
public protocol MusicSourceSyncProvider: Sendable {
    var sourceIdentifier: MusicSourceIdentifier { get }

    /// Sync the library content (artists, albums, tracks, genres) to CoreData
    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws
    
    /// Sync only items added or updated since the given timestamp (incremental sync)
    /// - Parameter since: Unix timestamp of last sync (fetch items added/updated after this)
    func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws
    
    /// Sync playlists to CoreData (should be called once per server, not per library)
    func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws

    /// Sync only playlists added or updated since last sync (incremental)
    func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws

    /// Get a streaming URL for a track
    func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality
    ) async throws -> URL

    /// Get an artwork URL
    func getArtworkURL(path: String?, size: Int) async throws -> URL?

    /// Rate a track (0-10)
    func rateTrack(ratingKey: String, rating: Int?) async throws

    /// Report playback timeline to the server
    func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws

    /// Scrobble a track (mark as played)
    func scrobble(ratingKey: String) async throws

    /// Reset any temporary fallback state for stream URL generation (e.g., universal endpoint cooldown).
    /// Called after a successful connection refresh so transient failures don't persist.
    func resetStreamFallbackState()

    /// Disable the universal transcode endpoint for this provider, forcing direct stream fallback.
    /// Called when AVPlayer reports a resource-unavailable error, indicating the transcode
    /// pipeline is broken (e.g., non-Plex Pass accounts). Expires after the provider's cooldown period.
    func disableUniversalEndpoint()

    /// Get tracks for an album directly from the source
    func getAlbumTracks(albumKey: String) async throws -> [Track]

    /// Get albums for an artist directly from the source
    func getArtistAlbums(artistKey: String) async throws -> [Album]

    /// Get all tracks for an artist directly from the source
    func getArtistTracks(artistKey: String) async throws -> [Track]
}

// Default no-op for providers that don't have fallback state
extension MusicSourceSyncProvider {
    public func resetStreamFallbackState() {}
    public func disableUniversalEndpoint() {}
}
