import Foundation

/// Owns provider-neutral playlist mutation control flow while each source provider
/// owns its remote API behavior.
@MainActor
final class PlaylistMutationController {
    struct Dependencies {
        let fetchPlaylists: (String?) async throws -> [Playlist]
        let persistCreatedPlaylist: (Playlist, [Track]) async throws -> Void
        let persistOptimisticAdd: ([Track], Playlist) async throws -> Int
        let reconcileAcceptedAdd: (
            MusicSourcePlaylistMutating,
            Playlist,
            [Track],
            Int
        ) async -> Void
        let persistLastPlaylistTarget: (Playlist) -> Void
        let clearLastPlaylistTargetIfNeeded: (Playlist) -> Void
        let deletePlaylistArtwork: (String, String) -> Void
        let refreshPlaylists: (String) async -> Void
        let refreshPlaylistsAfterMutation: (String, [Track]) async -> Void
    }

    private let dependencies: Dependencies
    private let actionService = PlaylistActionService()

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Create a playlist through its exact provider and reconcile the local cache.
    func createPlaylist(
        title: String,
        tracks: [Track],
        sourceKey: String,
        provider: MusicSourcePlaylistMutating
    ) async throws -> PlaylistMutationResult {
        guard MediaSourceIdentity.parse(sourceKey) != nil else {
            throw PlaylistMutationError.invalidSource
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlaylists = try await dependencies.fetchPlaylists(sourceKey)
        if existingPlaylists.contains(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistMutationError.duplicateName
        }

        let compatible = actionService.tracks(tracks, compatibleWithServerSourceKey: sourceKey)
        guard tracks.isEmpty || !compatible.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        let createdPlaylist = try await provider.createPlaylist(title: trimmed, tracks: compatible)
        if let createdPlaylist {
            try await dependencies.persistCreatedPlaylist(createdPlaylist, compatible)
            dependencies.persistLastPlaylistTarget(createdPlaylist)
        }
        Task { [dependencies] in
            await dependencies.refreshPlaylistsAfterMutation(sourceKey, compatible)
        }

        return PlaylistMutationResult(
            addedCount: compatible.count,
            skippedCount: tracks.count - compatible.count
        )
    }

    /// Add compatible tracks through the playlist's exact provider.
    func addTracksToPlaylist(
        _ tracks: [Track],
        playlist: Playlist,
        provider: MusicSourcePlaylistMutating
    ) async throws -> PlaylistMutationResult {
        let sourceKey = try mutableSourceKey(for: playlist)
        let compatible = actionService.tracks(tracks, compatibleWithServerSourceKey: sourceKey)
        guard !compatible.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        let added = try await provider.addTracks(compatible, to: playlist.id)
        dependencies.persistLastPlaylistTarget(playlist)
        let minimumTrackCount = (try? await dependencies.persistOptimisticAdd(compatible, playlist))
            ?? playlist.trackCount + added
        await dependencies.reconcileAcceptedAdd(
            provider,
            playlist,
            compatible,
            minimumTrackCount
        )

        return PlaylistMutationResult(
            addedCount: added,
            skippedCount: tracks.count - compatible.count
        )
    }

    /// Rename a playlist through its exact provider and reconcile the local cache.
    func renamePlaylist(
        _ playlist: Playlist,
        to newTitle: String,
        provider: MusicSourcePlaylistMutating
    ) async throws {
        let sourceKey = try mutableSourceKey(for: playlist)
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlaylists = try await dependencies.fetchPlaylists(sourceKey)
        if existingPlaylists.contains(where: {
            $0.id != playlist.id && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw PlaylistMutationError.duplicateName
        }

        try await provider.renamePlaylist(playlist.id, title: trimmed)
        await dependencies.refreshPlaylists(sourceKey)
    }

    /// Delete a playlist through its exact provider and reconcile local state.
    func deletePlaylist(
        _ playlist: Playlist,
        provider: MusicSourcePlaylistMutating
    ) async throws {
        let sourceKey = try mutableSourceKey(for: playlist)
        try await provider.deletePlaylist(playlist.id)
        dependencies.clearLastPlaylistTargetIfNeeded(playlist)
        dependencies.deletePlaylistArtwork(playlist.id, sourceKey)
        await dependencies.refreshPlaylists(sourceKey)
    }

    /// Replace playlist contents through its exact provider.
    func replacePlaylistContents(
        _ playlist: Playlist,
        with orderedTracks: [Track],
        provider: MusicSourcePlaylistMutating
    ) async throws {
        let sourceKey = try mutableSourceKey(for: playlist)
        let compatible = actionService.tracks(
            orderedTracks,
            compatibleWithServerSourceKey: sourceKey
        )
        guard orderedTracks.isEmpty || !compatible.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        try await provider.replacePlaylistContents(playlist.id, tracks: compatible)
        Task { [dependencies] in
            await dependencies.refreshPlaylistsAfterMutation(sourceKey, compatible)
        }
    }

    /// Apply provider-native membership edits and reconcile the local cache.
    func editPlaylistItems(
        _ playlist: Playlist,
        originalItems: [PlaylistItem],
        editedItems: [PlaylistItem],
        provider: MusicSourcePlaylistMutating
    ) async throws {
        let sourceKey = try mutableSourceKey(for: playlist)
        try await provider.editPlaylistItems(
            playlist.id,
            originalItems: originalItems,
            editedItems: editedItems
        )
        Task { [dependencies] in
            await dependencies.refreshPlaylistsAfterMutation(sourceKey, [])
        }
    }

    private func mutableSourceKey(for playlist: Playlist) throws -> String {
        guard !playlist.isSmart else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let sourceKey = playlist.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else {
            throw PlaylistMutationError.invalidSource
        }
        return sourceKey
    }
}
