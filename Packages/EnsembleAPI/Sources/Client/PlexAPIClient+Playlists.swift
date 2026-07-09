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
        return try await mediaContainerItems(path: "/playlists", query: query)
    }

    /// Get playlist inventory (just ratingKeys) for orphan detection
    public func getPlaylistInventory() async throws -> [PlexInventoryItem] {
        try await getPlaylists().map { PlexInventoryItem(ratingKey: $0.ratingKey) }
    }

    /// Get playlists added after a specific timestamp (incremental sync)
    public func getPlaylists(addedAfter timestamp: TimeInterval) async throws -> [PlexPlaylist] {
        let unixTime = Int(timestamp)
        return try await mediaContainerItems(
            path: "/playlists",
            query: ["playlistType": "audio", "addedAt>=": String(unixTime)]
        )
    }

    /// Get playlists updated after a specific timestamp (incremental sync)
    public func getPlaylists(updatedAfter timestamp: TimeInterval) async throws -> [PlexPlaylist] {
        let unixTime = Int(timestamp)
        return try await mediaContainerItems(
            path: "/playlists",
            query: ["playlistType": "audio", "updatedAt>=": String(unixTime)]
        )
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

        _ = try await serverRequestPOST(path: "/playlists", query: query)
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
        _ = try await serverRequestPUT(
            path: "/playlists/\(playlistId)/items",
            query: ["uri": uri]
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
        _ = try await serverRequestDELETE(path: "/playlists/\(playlistId)/items")
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
