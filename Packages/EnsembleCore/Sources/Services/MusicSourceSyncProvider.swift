import EnsemblePersistence
import Foundation

/// Protocol for syncing music from a source (Plex, future Apple Music, etc.)
public protocol MusicSourceSyncProvider: Sendable {
    var sourceIdentifier: MusicSourceIdentifier { get }

    /// Sync the library content (artists, albums, tracks, genres) to CoreData
    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws
    
    /// Sync playlists to CoreData (should be called once per server, not per library)
    func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws

    /// Get a streaming URL for a track
    func getStreamURL(for trackRatingKey: String, trackStreamKey: String?) async throws -> URL

    /// Get an artwork URL
    func getArtworkURL(path: String?, size: Int) async throws -> URL?
    
    /// Rate a track (0-10)
    func rateTrack(ratingKey: String, rating: Int?) async throws
}
