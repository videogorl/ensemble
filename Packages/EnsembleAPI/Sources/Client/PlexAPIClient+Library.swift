import Foundation

extension PlexAPIClient {
    /// Get library sections
    public func getLibrarySections() async throws -> [PlexLibrarySection] {
        let data = try await serverRequest(path: "/library/sections")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexLibrarySection>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get music library section - uses selected library if available, otherwise first music library
    public func getMusicLibrarySection() async throws -> PlexLibrarySection? {
        let sections = try await getLibrarySections()
        let musicSections = sections.filter { $0.isMusicLibrary }

        // If we have a selected library, try to find it
        if let selected = getLibrarySelection(),
           let match = musicSections.first(where: { $0.key == selected.key }) {
            return match
        }

        // Fallback to first music library
        return musicSections.first
    }

    /// Get all artists in a library section
    public func getArtists(sectionKey: String) async throws -> [PlexArtist] {
        let data = try await serverRequest(path: "/library/sections/\(sectionKey)/all", query: ["type": "8"])
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexArtist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get artists added or updated after a specific timestamp (incremental sync)
    public func getArtists(sectionKey: String, addedAfter timestamp: TimeInterval) async throws -> [PlexArtist] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "8", "addedAt>=": String(unixTime)]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexArtist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get artists updated after a specific timestamp (incremental sync)
    public func getArtists(sectionKey: String, updatedAfter timestamp: TimeInterval) async throws -> [PlexArtist] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "8", "updatedAt>=": String(unixTime)]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexArtist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all albums in a library section
    public func getAlbums(sectionKey: String) async throws -> [PlexAlbum] {
        let data = try await serverRequest(path: "/library/sections/\(sectionKey)/all", query: ["type": "9"])
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexAlbum>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get albums added or updated after a specific timestamp (incremental sync)
    public func getAlbums(sectionKey: String, addedAfter timestamp: TimeInterval) async throws -> [PlexAlbum] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "9", "addedAt>=": String(unixTime)]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexAlbum>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get albums updated after a specific timestamp (incremental sync)
    public func getAlbums(sectionKey: String, updatedAfter timestamp: TimeInterval) async throws -> [PlexAlbum] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "9", "updatedAt>=": String(unixTime)]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexAlbum>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get albums by an artist
    public func getArtistAlbums(artistKey: String) async throws -> [PlexAlbum] {
        let data = try await serverRequest(path: "/library/metadata/\(artistKey)/children")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexAlbum>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all tracks in a library section
    public func getTracks(sectionKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media"
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get tracks added or updated after a specific timestamp (incremental sync)
    public func getTracks(sectionKey: String, addedAfter timestamp: TimeInterval) async throws -> [PlexTrack] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media",
                "addedAt>=": String(unixTime)
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get tracks updated after a specific timestamp (incremental sync)
    public func getTracks(sectionKey: String, updatedAfter timestamp: TimeInterval) async throws -> [PlexTrack] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media",
                "updatedAt>=": String(unixTime)
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get tracks rated after a specific timestamp (for syncing rating changes from other devices)
    public func getTracks(sectionKey: String, ratedAfter timestamp: TimeInterval) async throws -> [PlexTrack] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media",
                "lastRatedAt>=": String(unixTime)
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get tracks in an album
    public func getAlbumTracks(albumKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(path: "/library/metadata/\(albumKey)/children")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all tracks by an artist
    public func getArtistTracks(artistKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(path: "/library/metadata/\(artistKey)/allLeaves")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get genres in a library section
    public func getGenres(sectionKey: String) async throws -> [PlexGenre] {
        let data = try await serverRequest(path: "/library/sections/\(sectionKey)/genre")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexGenre>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all artist ratingKeys in a library section (minimal response)
    /// Uses includeFields=ratingKey to reduce response size significantly
    public func getArtistInventory(sectionKey: String) async throws -> [PlexInventoryItem] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "8",
                "includeFields": "ratingKey",
                "excludeElements": "Media,Genre,Country,Guid,Rating,Collection,Director,Writer,Role"
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexInventoryItem>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all album ratingKeys in a library section (minimal response)
    public func getAlbumInventory(sectionKey: String) async throws -> [PlexInventoryItem] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "9",
                "includeFields": "ratingKey",
                "excludeElements": "Media,Genre,Country,Guid,Rating,Collection,Director,Writer,Role"
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexInventoryItem>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all track ratingKeys in a library section (minimal response)
    public func getTrackInventory(sectionKey: String) async throws -> [PlexInventoryItem] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "10",
                "includeFields": "ratingKey",
                "excludeElements": "Media,Genre,Mood,Guid,Rating"
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexInventoryItem>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get moods in a library section
    public func getMoods(sectionKey: String) async throws -> [PlexMood] {
        let data = try await serverRequest(path: "/library/sections/\(sectionKey)/mood")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexMood>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get tracks by genre
    public func getTracksByGenre(sectionKey: String, genreKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "10", "genre": genreKey]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get tracks by mood
    public func getTracksByMood(sectionKey: String, moodKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "10", "mood": moodKey]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get all hubs for a library section (Recently Added, Recently Played, etc.)
    public func getHubs(sectionKey: String, count: String = "12") async throws -> [PlexHub] {
        let data = try await serverRequest(
            path: "/hubs/sections/\(sectionKey)",
            query: [
                "count": count,
                "includeLibrary": "1",
                "includeExternalMedia": "1",
                "excludeFields": "summary"
            ]
        )

        EnsembleLogger.debug("🏠 Received hubs payload for Section \(sectionKey): \(data.count) bytes")

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHub>.self,
            from: data
        )
        let hubs = container.mediaContainer.items
        EnsembleLogger.debug("🏠 Decoded \(hubs.count) hubs from Section \(sectionKey)")
        return hubs
    }

    /// Get global hubs (across all libraries)
    public func getGlobalHubs() async throws -> [PlexHub] {
        let data = try await serverRequest(
            path: "/hubs",
            query: [
                "count": "12",
                "includeLibrary": "1",
                "includeExternalMedia": "1",
                "excludeFields": "summary"
            ]
        )

        EnsembleLogger.debug("🏠 Received global hubs payload: \(data.count) bytes")

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHub>.self,
            from: data
        )
        let hubs = container.mediaContainer.items
        EnsembleLogger.debug("🏠 Decoded \(hubs.count) global hubs")
        return hubs
    }

    /// Get items for a specific hub
    public func getHubItems(hubKey: String) async throws -> [PlexHubMetadata] {
        let data = try await serverRequest(path: hubKey)
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHubMetadata>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Search library
    public func search(query: String, sectionKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/search",
            query: ["type": "10", "query": query]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Rate a track (0 = no rating, 2 = 1 star, 4 = 2 stars, ..., 10 = 5 stars)
    /// Pass nil or 0 to remove rating
    public func rateTrack(ratingKey: String, rating: Int?) async throws {
        let ratingValue = rating ?? 0
        guard ratingValue >= 0 && ratingValue <= 10 else {
            throw PlexAPIError.invalidURL
        }

        _ = try await serverRequestPUT(
            path: "/:/rate",
            query: [
                "key": ratingKey,
                "identifier": "com.plexapp.plugins.library",
                "rating": String(ratingValue)
            ]
        )
    }
}
