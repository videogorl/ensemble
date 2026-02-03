import EnsemblePersistence
import Foundation

/// Protocol for syncing music from a source (Plex, future Apple Music, etc.)
public protocol MusicSourceSyncProvider: Sendable {
    var sourceIdentifier: MusicSourceIdentifier { get }

    /// Sync the full library to CoreData
    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws

    /// Get a streaming URL for a track
    func getStreamURL(for trackRatingKey: String, trackStreamKey: String?) async throws -> URL

    /// Get an artwork URL
    func getArtworkURL(path: String?, size: Int) async throws -> URL?
}
