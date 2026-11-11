import Foundation

extension PlexAPIClient {
    /// Get audio playlists
    public func getPlaylists() async throws -> [PlexPlaylist] {
        try await getPlaylists(limit: nil)
    }

    /// Get audio playlists with an optional Plex container cap.
    public func getPlaylists(limit: Int?) async throws -> [PlexPlaylist] {
        var query = ["playlistType": "audio"]
        if let limit {
            query["X-Plex-Container-Start"] = "0"
            query["X-Plex-Container-Size"] = String(limit)
        }
        return PlexPlaylist.deduplicated(
            try await mediaContainerItems(path: "/playlists", query: query)
        )
    }

    /// Every audio playlist, and whether the response proves the list complete: the container reports a
    /// size, no total or offset contradicts it, it equals the rows received, and no playlist repeats.
    /// An unproven list is still usable for upserts, but never to delete.
    public func getPlaylistList() async throws -> (playlists: [PlexPlaylist], isComplete: Bool) {
        try Self.decodePlaylistList(try await serverRequest(path: "/playlists", query: ["playlistType": "audio"]))
    }

    static func decodePlaylistList(_ data: Data) throws -> (playlists: [PlexPlaylist], isComplete: Bool) {
        let content = try JSONDecoder().decode(PlexMediaContainer<PlexPlaylist>.self, from: data).mediaContainer
        let playlists = PlexPlaylist.deduplicated(content.items)
        let isComplete = content.size == content.items.count
            && (content.totalSize ?? content.items.count) == content.items.count
            && (content.offset ?? 0) == 0
            && playlists.count == content.items.count
        return (playlists, isComplete)
    }

    /// Get playlist tracks
    public func getPlaylistTracks(playlistKey: String) async throws -> [PlexTrack] {
        EnsembleLogger.debug("🎵 PlexAPIClient.getPlaylistTracks() called")
        EnsembleLogger.debug("  - Playlist key: \(playlistKey)")
        EnsembleLogger.debug("🔄 Fetching playlist items from /playlists/\(playlistKey)/items...")

        let data = try await serverRequest(path: "/playlists/\(playlistKey)/items")
        EnsembleLogger.debug("✅ Got response data (\(data.count) bytes)")
        EnsembleLogger.debug("🔄 Decoding playlist tracks...")

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        let content = container.mediaContainer
        guard content.offset == nil || content.offset == 0,
              content.size == content.items.count,
              content.totalSize == nil || content.totalSize == content.items.count else {
            throw PlexAPIError.invalidResponse
        }
        EnsembleLogger.debug("✅ Got \(container.mediaContainer.items.count) playlist tracks")
        return container.mediaContainer.items
    }

    /// Create a new audio playlist
    public func createPlaylist(title: String, trackRatingKeys: [String], serverIdentifier: String) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlexAPIError.invalidURL
        }

        var query: [String: String] = [
            "type": "audio",
            "title": title,
            "smart": "0"
        ]
        if !trackRatingKeys.isEmpty {
            query["uri"] = buildMetadataURI(serverIdentifier: serverIdentifier, ratingKeys: trackRatingKeys)
        }

        // PMS may have created the playlist even if its acknowledgment was lost.
        _ = try await serverRequestPOST(path: "/playlists", query: query, retryAfterFailover: false)
    }

    /// Rename an existing playlist
    public func renamePlaylist(playlistId: String, newTitle: String) async throws {
        guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlexAPIError.invalidURL
        }

        _ = try await serverRequestPUT(
            path: "/playlists/\(playlistId)",
            query: ["title": newTitle]
        )
    }

    /// Add tracks to an existing playlist
    public func addItemsToPlaylist(playlistId: String, trackRatingKeys: [String], serverIdentifier: String) async throws {
        let uri = buildMetadataURI(serverIdentifier: serverIdentifier, ratingKeys: trackRatingKeys)
        // Let the mutation owner reconcile membership before retrying an ambiguous append.
        _ = try await serverRequestPUT(
            path: "/playlists/\(playlistId)/items",
            query: ["uri": uri],
            retryAfterFailover: false
        )
    }

    /// Delete a playlist.
    public func deletePlaylist(playlistId: String) async throws {
        _ = try await serverRequestDELETE(path: "/playlists/\(playlistId)")
    }

    /// Remove a specific playlist item from a playlist
    public func removePlaylistItem(playlistId: String, playlistItemId: String) async throws {
        _ = try await serverRequestDELETE(path: "/playlists/\(playlistId)/items/\(playlistItemId)")
    }

    /// Clear all items from a playlist
    public func clearPlaylistItems(playlistId: String) async throws {
        // A repeated clear could remove items added after an unacknowledged first clear.
        _ = try await serverRequestDELETE(path: "/playlists/\(playlistId)/items", retryAfterFailover: false)
    }

    /// Move a playlist item relative to another item
    public func movePlaylistItem(playlistId: String, playlistItemId: String, afterItemId: String?) async throws {
        var query: [String: String] = [:]
        if let afterItemId {
            query["after"] = afterItemId
        }
        _ = try await serverRequestPUT(
            path: "/playlists/\(playlistId)/items/\(playlistItemId)/move",
            query: query
        )
    }
}
