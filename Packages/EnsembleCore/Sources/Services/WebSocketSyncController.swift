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

    func resolveSections(
        sectionKey: String,
        serverKey: String,
        providers: [String: MusicSourceSyncProvider],
        knownSources: Set<MusicSourceIdentifier>
    ) -> [SectionResolution] {
        let parts = serverKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return [] }
        let serverId = String(parts[1])

        return providers.compactMap { compositeKey, provider in
            let sourceId = provider.sourceIdentifier
            guard sourceId.serverId == serverId,
                  sourceId.libraryId == sectionKey,
                  knownSources.contains(sourceId) else { return nil }
            return SectionResolution(sourceId: sourceId, compositeKey: compositeKey)
        }
        .sorted { $0.compositeKey < $1.compositeKey }
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
