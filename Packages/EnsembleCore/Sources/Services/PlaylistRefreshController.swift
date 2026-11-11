import Foundation

/// Owns server-scoped playlist refresh orchestration so SyncCoordinator does not
/// carry separate mutation, playlist-only, and WebSocket refresh loops inline.
@MainActor
final class PlaylistRefreshController {
    enum Trigger {
        case mutationRefresh
        case playlistOnly
        case webSocket
        case downloadedPlaylist

        var description: String {
            switch self {
            case .mutationRefresh:
                return "mutation refresh"
            case .playlistOnly:
                return "playlist-only sync"
            case .webSocket:
                return "websocket sync"
            case .downloadedPlaylist:
                return "downloaded-playlist sync"
            }
        }
    }

    struct RefreshResult {
        let sourceId: MusicSourceIdentifier
        let serverSourceKey: String
        let provider: MusicSourceConnector
        let playlistResult: PlaylistSyncResult
    }

    /// Reads a source's playlist list, then the bodies the writer says it needs, and hands both to the
    /// writer as one batch. Every pass reads the whole list, so a missing cursor needs no separate full sync.
    func sync(
        provider: MusicSourceConnector,
        writer: LibraryWriter,
        progressHandler: @Sendable (Double) -> Void = { _ in }
    ) async throws -> PlaylistSyncResult {
        guard let scope = MediaSourceIdentity.playlistScopeKey(from: provider.sourceIdentifier.compositeKey) else {
            throw PlaylistMutationError.invalidSource
        }
        progressHandler(0.1)
        let list = try await provider.fetchPlaylistHeaders()
        progressHandler(0.4)
        let needed = try await writer.playlistsNeedingBodies(list.headers, for: scope)
        let bodies = try await provider.fetchPlaylistBodies(for: needed)
        progressHandler(0.8)
        let result = try await writer.apply(PlaylistBatch(list: list, bodies: bodies), for: scope)
        progressHandler(1)
        return result
    }

    func refreshAllServers(
        providers: [String: MusicSourceConnector],
        writer: LibraryWriter,
        trigger: Trigger
    ) async -> [RefreshResult] {
        var refreshedServerKeys = Set<String>()
        var results: [RefreshResult] = []

        for provider in providers.values {
            let sourceId = provider.sourceIdentifier
            let serverKey = MediaSourceIdentity.serverSourceKey(for: sourceId)

            guard !refreshedServerKeys.contains(serverKey) else { continue }
            refreshedServerKeys.insert(serverKey)

            do {
                if let result = try await refreshServer(
                    serverSourceKey: serverKey,
                    providers: providers,
                    writer: writer,
                    trigger: trigger
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
        providers: [String: MusicSourceConnector],
        writer: LibraryWriter,
        trigger: Trigger
    ) async throws -> RefreshResult? {
        guard let parsed = MediaSourceIdentity.parse(serverSourceKey),
              let provider = providers.values.first(where: {
                  MediaSourceIdentity.isSameServer($0.sourceIdentifier.compositeKey, parsed.serverSourceKey)
              })
        else { return nil }
        let sourceId = provider.sourceIdentifier

        do {
            return RefreshResult(
                sourceId: sourceId,
                serverSourceKey: MediaSourceIdentity.serverSourceKey(for: sourceId),
                provider: provider,
                playlistResult: try await sync(provider: provider, writer: writer)
            )
        } catch is CancellationError {
            EnsembleLogger.debug("⏹️ PlaylistRefreshController: \(trigger.description) cancelled for \(serverSourceKey)")
            throw CancellationError()
        } catch {
            EnsembleLogger.debug(
                "⚠️ PlaylistRefreshController: \(trigger.description) failed for \(serverSourceKey): \(error.localizedDescription)"
            )
            return nil
        }
    }
}
