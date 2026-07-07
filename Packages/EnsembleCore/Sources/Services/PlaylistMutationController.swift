import Foundation

/// Owns playlist mutation control flow while the facade keeps source parsing,
/// transport helpers, and cache-refresh side effects.
@MainActor
final class PlaylistMutationController {
    struct Dependencies {
        let validateServerSourceKey: (String) -> Bool
        let fetchPlaylists: (String?) async throws -> [Playlist]
        let filteredTrackIDsForServer: ([Track], String) async -> [String]
        let createRemotePlaylist: (String, [String], String) async throws -> Void
        let reconcileCreatedPlaylist: (String, [String], String, Bool) async -> Playlist?
        let addTracksToRemotePlaylist: (String, [String], String) async throws -> Void
        let renameRemotePlaylist: (String, String, String) async throws -> Void
        let deleteRemotePlaylist: (String, String) async throws -> Void
        let replaceRemotePlaylistContents: (String, [String], String) async throws -> Void
        let persistLastPlaylistTarget: (Playlist) -> Void
        let clearLastPlaylistTargetIfNeeded: (Playlist) -> Void
        let refreshServerPlaylists: (String) async -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Create a new playlist, persist the local target metadata, and queue a refresh.
    func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        guard dependencies.validateServerSourceKey(serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlaylists = try await dependencies.fetchPlaylists(serverSourceKey)
        if existingPlaylists.contains(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistMutationError.duplicateName
        }

        let filteredTrackIds = await dependencies.filteredTrackIDsForServer(tracks, serverSourceKey)
        guard tracks.isEmpty || !filteredTrackIds.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        try await dependencies.createRemotePlaylist(trimmed, filteredTrackIds, serverSourceKey)

        if let createdPlaylist = await dependencies.reconcileCreatedPlaylist(
            trimmed,
            filteredTrackIds,
            serverSourceKey,
            tracks.isEmpty
        ) {
            dependencies.persistLastPlaylistTarget(createdPlaylist)
        }

        Task { [dependencies] in
            await dependencies.refreshServerPlaylists(serverSourceKey)
        }

        let skippedCount = max(0, tracks.count - filteredTrackIds.count)
        return PlaylistMutationResult(addedCount: filteredTrackIds.count, skippedCount: skippedCount)
    }

    /// Add tracks to an existing playlist and queue a server refresh.
    func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async throws -> PlaylistMutationResult {
        let serverSourceKey = try mutableServerSourceKey(for: playlist)

        let filteredTrackIds = await dependencies.filteredTrackIDsForServer(tracks, serverSourceKey)
        guard !filteredTrackIds.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        try await dependencies.addTracksToRemotePlaylist(playlist.id, filteredTrackIds, serverSourceKey)

        Task { [dependencies] in
            await dependencies.refreshServerPlaylists(serverSourceKey)
        }

        dependencies.persistLastPlaylistTarget(playlist)
        let skippedCount = max(0, tracks.count - filteredTrackIds.count)
        return PlaylistMutationResult(addedCount: filteredTrackIds.count, skippedCount: skippedCount)
    }

    /// Rename a playlist and synchronously refresh its server cache.
    func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws {
        let serverSourceKey = try mutableServerSourceKey(for: playlist)

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlaylists = try await dependencies.fetchPlaylists(serverSourceKey)
        if existingPlaylists.contains(where: { $0.id != playlist.id && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistMutationError.duplicateName
        }

        try await dependencies.renameRemotePlaylist(playlist.id, trimmed, serverSourceKey)
        await dependencies.refreshServerPlaylists(serverSourceKey)
    }

    /// Delete a playlist, clear persisted targeting if needed, and refresh its server cache.
    func deletePlaylist(_ playlist: Playlist) async throws {
        let serverSourceKey = try mutableServerSourceKey(for: playlist)

        try await dependencies.deleteRemotePlaylist(playlist.id, serverSourceKey)
        dependencies.clearLastPlaylistTargetIfNeeded(playlist)
        await dependencies.refreshServerPlaylists(serverSourceKey)
    }

    /// Replace a playlist's contents in the supplied order and refresh its cache.
    func replacePlaylistContents(_ playlist: Playlist, with orderedTracks: [Track]) async throws {
        let serverSourceKey = try mutableServerSourceKey(for: playlist)

        let filteredTrackIds = await dependencies.filteredTrackIDsForServer(orderedTracks, serverSourceKey)
        guard orderedTracks.isEmpty || !filteredTrackIds.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }
        try await dependencies.replaceRemotePlaylistContents(playlist.id, filteredTrackIds, serverSourceKey)
        await dependencies.refreshServerPlaylists(serverSourceKey)
    }

    private func mutableServerSourceKey(for playlist: Playlist) throws -> String {
        guard !playlist.isSmart else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let serverSourceKey = playlist.sourceCompositeKey,
              dependencies.validateServerSourceKey(serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        return serverSourceKey
    }
}
