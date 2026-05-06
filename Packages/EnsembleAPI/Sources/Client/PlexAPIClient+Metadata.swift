import Foundation

extension PlexAPIClient {
    /// Get detailed artist metadata (genres, country, similar artists, styles, GUIDs).
    /// Uses the single-item metadata endpoint which returns richer data than the section listing.
    public func getArtistDetail(artistKey: String) async throws -> PlexArtistDetail? {
        let data = try await serverRequest(path: "/library/metadata/\(artistKey)")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexArtistDetail>.self,
            from: data
        )
        return container.mediaContainer.items.first
    }

    /// Get detailed album metadata (genres, styles, studio, GUIDs).
    /// Uses the single-item metadata endpoint which returns richer data than the section listing.
    public func getAlbumDetail(albumKey: String) async throws -> PlexAlbumDetail? {
        let data = try await serverRequest(path: "/library/metadata/\(albumKey)")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexAlbumDetail>.self,
            from: data
        )
        return container.mediaContainer.items.first
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
        let data = try await serverRequest(path: "/library/metadata/\(trackKey)")

        #if DEBUG
        if let jsonString = String(data: data, encoding: .utf8) {
            EnsembleLogger.debug("🔍 Raw JSON response (first 500 chars): \(String(jsonString.prefix(500)))")
        }
        #endif

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        let track = container.mediaContainer.items.first

        if let track {
            EnsembleLogger.debug("🔍 getTrack - media count: \(track.media?.count ?? 0)")
            if let media = track.media?.first {
                EnsembleLogger.debug("🔍 getTrack - part count: \(media.part?.count ?? 0)")
                if let part = media.part?.first {
                    EnsembleLogger.debug("🔍 getTrack - part key: \(part.key ?? "nil")")
                    EnsembleLogger.debug("🔍 getTrack - part file: \(part.file ?? "nil")")
                }
            }
        }

        return track
    }

    /// Get multiple tracks in a single batch request
    /// This is more efficient than making multiple getTrack calls when you need to fetch several tracks
    public func getTracks(ratingKeys: [String]) async throws -> [PlexTrack] {
        guard !ratingKeys.isEmpty else { return [] }

        let ids = ratingKeys.joined(separator: ",")

        EnsembleLogger.debug("📦 Fetching \(ratingKeys.count) tracks in batch")

        let data = try await serverRequest(path: "/library/metadata/\(ids)")

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
