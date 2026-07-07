import Foundation

/// Owns server-scoped playlist refresh orchestration so SyncCoordinator does not
/// carry separate mutation, playlist-only, and WebSocket refresh loops inline.
@MainActor
final class PlaylistRefreshController {
    enum Trigger {
        case mutationRefresh
        case playlistOnly
        case webSocket

        var description: String {
            switch self {
            case .mutationRefresh:
                return "mutation refresh"
            case .playlistOnly:
                return "playlist-only sync"
            case .webSocket:
                return "websocket sync"
            }
        }

        var forcesPlaylistOrphanCheck: Bool {
            switch self {
            case .mutationRefresh, .playlistOnly:
                return true
            case .webSocket:
                return false
            }
        }
    }

    struct RefreshResult {
        let sourceId: MusicSourceIdentifier
        let serverSourceKey: String
        let provider: MusicSourceSyncProvider
        let playlistResult: PlaylistSyncResult
    }

    func refreshAllServers(
        providers: [String: MusicSourceSyncProvider],
        playlistRepository: PlaylistRepositoryProtocol,
        trigger: Trigger,
        allowFullFallback: Bool
    ) async -> [RefreshResult] {
        var refreshedServerKeys = Set<String>()
        var results: [RefreshResult] = []

        for provider in providers.values {
            let sourceId = provider.sourceIdentifier
            let serverKey = "\(sourceId.accountId):\(sourceId.serverId)"

            guard !refreshedServerKeys.contains(serverKey) else { continue }
            refreshedServerKeys.insert(serverKey)

            do {
                if let result = try await refreshServer(
                    serverSourceKey: "plex:\(serverKey)",
                    providers: providers,
                    playlistRepository: playlistRepository,
                    trigger: trigger,
                    allowFullFallback: allowFullFallback
                ) {
                    results.append(result)
                }
            } catch is CancellationError {
                EnsembleLogger.debug("⏹️ PlaylistRefreshController: \(trigger.description) cancelled for server \(serverKey)")
            } catch {
                EnsembleLogger.debug(
                    "⚠️ PlaylistRefreshController: \(trigger.description) failed for server \(serverKey): \(error.localizedDescription)"
                )
            }
        }

        return results
    }

    func refreshServer(
        serverSourceKey: String,
        providers: [String: MusicSourceSyncProvider],
        playlistRepository: PlaylistRepositoryProtocol,
        trigger: Trigger,
        allowFullFallback: Bool
    ) async throws -> RefreshResult? {
        guard let parsed = MediaSourceIdentity.parse(serverSourceKey) else {
            return nil
        }

        for (_, provider) in providers where
            provider.sourceIdentifier.accountId == parsed.accountId &&
            provider.sourceIdentifier.serverId == parsed.serverId {
            let sourceId = provider.sourceIdentifier

            do {
                if trigger.forcesPlaylistOrphanCheck {
                    PlexMusicSourceSyncProvider.resetPlaylistOrphanCheckTimestamp(for: serverSourceKey)
                }

                let playlistResult = try await provider.syncPlaylistsIncremental(
                    to: playlistRepository,
                    progressHandler: { _ in }
                )
                return RefreshResult(
                    sourceId: sourceId,
                    serverSourceKey: "plex:\(sourceId.accountId):\(sourceId.serverId)",
                    provider: provider,
                    playlistResult: playlistResult
                )
            } catch is CancellationError {
                EnsembleLogger.debug("⏹️ PlaylistRefreshController: \(trigger.description) cancelled for \(serverSourceKey)")
                throw CancellationError()
            } catch {
                guard allowFullFallback else {
                    EnsembleLogger.debug(
                        "⚠️ PlaylistRefreshController: \(trigger.description) incremental refresh failed for \(serverSourceKey): \(error.localizedDescription)"
                    )
                    return nil
                }

                do {
                    let playlistResult = try await provider.syncPlaylists(
                        to: playlistRepository,
                        progressHandler: { _ in }
                    )
                    return RefreshResult(
                        sourceId: sourceId,
                        serverSourceKey: "plex:\(sourceId.accountId):\(sourceId.serverId)",
                        provider: provider,
                        playlistResult: playlistResult
                    )
                } catch {
                    EnsembleLogger.debug(
                        "⚠️ PlaylistRefreshController: \(trigger.description) full fallback failed for \(serverSourceKey): \(error.localizedDescription)"
                    )
                    return nil
                }
            }
        }

        return nil
    }

}
