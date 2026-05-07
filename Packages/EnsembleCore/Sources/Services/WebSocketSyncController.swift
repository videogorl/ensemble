import Foundation

/// Owns WebSocket-triggered sync resolution so SyncCoordinator does not have to
/// inline provider lookups for section and playlist updates.
@MainActor
final class WebSocketSyncController {
    struct SectionResolution: Equatable {
        let sourceId: MusicSourceIdentifier
        let compositeKey: String
    }

    struct PlaylistResolution {
        let sourceId: MusicSourceIdentifier
        let serverSourceKey: String
        let provider: MusicSourceSyncProvider
        let playlistResult: PlaylistSyncResult
    }

    func resolveSection(
        sectionKey: String,
        providers: [String: MusicSourceSyncProvider],
        knownSources: Set<MusicSourceIdentifier>
    ) -> SectionResolution? {
        guard let (compositeKey, provider) = providers.first(where: { (_, provider) in
            provider.sourceIdentifier.libraryId == sectionKey
        }) else {
            return nil
        }

        let sourceId = provider.sourceIdentifier
        guard knownSources.contains(sourceId) else {
            return nil
        }

        return SectionResolution(sourceId: sourceId, compositeKey: compositeKey)
    }

    func refreshServerPlaylists(
        serverKey: String,
        providers: [String: MusicSourceSyncProvider],
        playlistRepository: PlaylistRepositoryProtocol,
        playlistRefreshController: PlaylistRefreshController
    ) async throws -> PlaylistResolution? {
        guard let result = try await playlistRefreshController.refreshServer(
            serverSourceKey: "plex:\(serverKey)",
            providers: providers,
            playlistRepository: playlistRepository,
            trigger: .webSocket,
            allowFullFallback: false
        ) else {
            return nil
        }

        return PlaylistResolution(
            sourceId: result.sourceId,
            serverSourceKey: result.serverSourceKey,
            provider: result.provider,
            playlistResult: result.playlistResult
        )
    }
}
