import Foundation

/// Owns WebSocket-triggered sync resolution so SyncCoordinator does not have to
/// inline provider lookups for section and playlist updates.
@MainActor
final class WebSocketSyncController {
    struct SectionResolution: Equatable {
        let sourceId: MusicSourceIdentifier
        let compositeKey: String
    }

    func resolveSections(
        sectionKey: String,
        serverKey: String,
        providers: [String: MusicSourceSyncProvider],
        knownSources: Set<MusicSourceIdentifier>
    ) -> [SectionResolution] {
        let parts = serverKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return [] }
        let accountId = String(parts[0])
        let serverId = String(parts[1])

        return providers.compactMap { compositeKey, provider in
            let sourceId = provider.sourceIdentifier
            guard sourceId.type == .plex,
                  sourceId.accountId == accountId,
                  sourceId.serverId == serverId,
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
    ) async throws -> PlaylistRefreshController.RefreshResult? {
        try await playlistRefreshController.refreshServer(
            serverSourceKey: "plex:\(serverKey)",
            providers: providers,
            playlistRepository: playlistRepository,
            trigger: .webSocket,
            allowFullFallback: false
        )
    }
}
