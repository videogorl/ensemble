import Foundation
import EnsemblePersistence

#if !os(macOS)
import Intents

@MainActor
public final class SiriMediaUserContextManager {
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider?
    // Track last published count to skip duplicate updates
    private var lastPublishedItemCount: Int?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.enabledSourceKeysProvider = enabledSourceKeysProvider
    }
    
    public func updateMediaUserContext() async {
        do {
            let enabledLibrarySourceKeys = enabledSourceKeysProvider?()
            let playlistSourceKeys = enabledLibrarySourceKeys.map {
                SystemMediaSourceScope.playlistSourceKeys(forEnabledLibraryKeys: $0)
            }

            // Gather counts without materializing full CoreData collections.
            async let trackCountTask = libraryRepository.countTracks(sourceCompositeKeys: enabledLibrarySourceKeys)
            async let albumCountTask = libraryRepository.countAlbums(sourceCompositeKeys: enabledLibrarySourceKeys)
            async let artistCountTask = libraryRepository.countArtists(sourceCompositeKeys: enabledLibrarySourceKeys)
            async let playlistCountTask = playlistRepository.countPlaylists(sourceCompositeKeys: playlistSourceKeys)
            let counts = try await (trackCountTask, albumCountTask, artistCountTask, playlistCountTask)
            let trackCount = counts.0
            let albumCount = counts.1
            let artistCount = counts.2
            let playlistCount = counts.3
            let totalItems = trackCount + albumCount + artistCount + playlistCount

            // Skip if the count hasn't changed since last publish
            guard totalItems != lastPublishedItemCount else {
                EnsembleLogger.debug("🎯 INMediaUserContext unchanged (\(totalItems) items) — skipping")
                return
            }

            // Create and configure media user context
            let context = INMediaUserContext()
            context.numberOfLibraryItems = totalItems
            context.subscriptionStatus = .unknown

            // Share context with Siri
            context.becomeCurrent()
            lastPublishedItemCount = totalItems

            EnsembleLogger.debug("🎯 Updated INMediaUserContext: \(totalItems) items (\(trackCount) tracks, \(albumCount) albums, \(artistCount) artists, \(playlistCount) playlists), status=unknown")
        } catch {
            EnsembleLogger.debug("⚠️ Failed to update INMediaUserContext: \(error.localizedDescription)")
        }
    }
}

#else

// Stub implementation for macOS (Intents not available)
@MainActor
public final class SiriMediaUserContextManager {
    public init(
        libraryRepository _: LibraryRepositoryProtocol,
        playlistRepository _: PlaylistRepositoryProtocol,
        enabledSourceKeysProvider _: SystemMediaEnabledSourceKeysProvider? = nil
    ) {}
    
    public func updateMediaUserContext() async {
        // No-op on macOS
    }
}

#endif
