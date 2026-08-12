import Foundation

extension PlexAPIClient {
    private func getMetadata<T: Codable & Sendable>(
        _ type: T.Type,
        ratingKey: String,
        query: [String: String] = [:]
    ) async throws -> T? {
        let data = try await serverRequest(
            path: "/library/metadata/\(ratingKey)",
            query: query
        )
        let container = try JSONDecoder().decode(PlexMediaContainer<T>.self, from: data)
        return container.mediaContainer.items.first
    }

    /// Get one artist using the authoritative single-item metadata endpoint.
    public func getArtist(artistKey: String) async throws -> PlexArtist? {
        try await getMetadata(PlexArtist.self, ratingKey: artistKey)
    }

    /// Get one album using the authoritative single-item metadata endpoint.
    public func getAlbum(albumKey: String) async throws -> PlexAlbum? {
        try await getMetadata(PlexAlbum.self, ratingKey: albumKey)
    }

    /// Get detailed artist metadata (genres, country, similar artists, styles, GUIDs).
    /// Uses the single-item metadata endpoint which returns richer data than the section listing.
    public func getArtistDetail(artistKey: String) async throws -> PlexArtistDetail? {
        try await getMetadata(PlexArtistDetail.self, ratingKey: artistKey)
    }

    /// Get detailed album metadata (genres, styles, studio, GUIDs).
    /// Uses the single-item metadata endpoint which returns richer data than the section listing.
    public func getAlbumDetail(albumKey: String) async throws -> PlexAlbumDetail? {
        try await getMetadata(PlexAlbumDetail.self, ratingKey: albumKey)
    }

    /// Get sonically similar albums from Plex's recommendation engine.
    /// Uses the /library/metadata/{id}/related endpoint which returns hub-based results.
    /// The "Sonically Similar Albums" hub contains album metadata items.
    public func getSimilarAlbums(albumKey: String) async throws -> [PlexHubMetadata] {
        let data = try await serverRequest(path: "/library/metadata/\(albumKey)/related")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHub>.self,
            from: data
        )
        let hubs = container.mediaContainer.items
        let albumHub = hubs.first { $0.type == "album" }
        return albumHub?.metadata ?? []
    }

    /// Get a single track
    public func getTrack(trackKey: String) async throws -> PlexTrack? {
        try await getMetadata(
            PlexTrack.self,
            ratingKey: trackKey,
            query: [
                "includeMedia": "1",
                "includeElements": "Media"
            ]
        )
    }

    /// Get multiple tracks in a single batch request
    /// This is more efficient than making multiple getTrack calls when you need to fetch several tracks
    public func getTracks(ratingKeys: [String]) async throws -> [PlexTrack] {
        guard !ratingKeys.isEmpty else { return [] }

        let ids = ratingKeys.joined(separator: ",")

        EnsembleLogger.debug("📦 Fetching \(ratingKeys.count) tracks in batch")

        let data = try await serverRequest(
            path: "/library/metadata/\(ids)",
            query: [
                "includeMedia": "1",
                "includeElements": "Media"
            ]
        )

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )

        EnsembleLogger.debug("✅ Batch fetch returned \(container.mediaContainer.items.count) tracks")

        return container.mediaContainer.items
    }

    /// Delete one or more metadata items from the library.
    public func deleteMetadata(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await serverRequestDELETE(path: "/library/metadata/\(ids.joined(separator: ","))")
    }

    /// Update metadata fields using Plex's section bulk-edit endpoint.
    public func updateMetadata(
        sectionId: String,
        metadataType: Int,
        ids: [String],
        fieldUpdates: [PlexMetadataFieldUpdate]
    ) async throws {
        guard !ids.isEmpty, !fieldUpdates.isEmpty else { return }

        var query: [String: String] = [
            "type": String(metadataType),
            "id": ids.joined(separator: ",")
        ]

        for update in fieldUpdates {
            if let value = update.value {
                query["\(update.fieldName).value"] = value
            }
            if let isLocked = update.isLocked {
                query["\(update.fieldName).locked"] = isLocked ? "1" : "0"
            }
        }

        _ = try await serverRequestPUT(path: "/library/sections/\(sectionId)/all", query: query)
    }
}
