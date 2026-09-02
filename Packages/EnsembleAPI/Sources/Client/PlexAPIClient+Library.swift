import Foundation

extension PlexAPIClient {
    private static let libraryPageSize = 500

    private func getPagedSectionItems<T: Codable & Sendable>(
        sectionKey: String,
        baseQuery: [String: String],
        pageSize: Int = PlexAPIClient.libraryPageSize
    ) async throws -> [T] {
        var allItems: [T] = []
        var start = 0
        var expectedTotalSize: Int?

        while true {
            var query = baseQuery
            query["X-Plex-Container-Start"] = String(start)
            query["X-Plex-Container-Size"] = String(pageSize)

            let data = try await serverRequest(
                path: "/library/sections/\(sectionKey)/all",
                query: query
            )
            let container = try JSONDecoder().decode(
                PlexMediaContainer<T>.self,
                from: data
            )

            let items = container.mediaContainer.items
            guard container.mediaContainer.size == items.count,
                  let totalSize = container.mediaContainer.totalSize,
                  expectedTotalSize == nil || expectedTotalSize == totalSize,
                  container.mediaContainer.offset == nil || container.mediaContainer.offset == start else {
                throw PlexAPIError.invalidResponse
            }
            expectedTotalSize = totalSize

            guard !items.isEmpty else {
                guard start == totalSize else { throw PlexAPIError.invalidResponse }
                break
            }

            allItems.append(contentsOf: items)

            let nextStart = start + items.count
            guard nextStart <= totalSize else { throw PlexAPIError.invalidResponse }
            if nextStart == totalSize {
                break
            }
            guard items.count == pageSize else { throw PlexAPIError.invalidResponse }
            start = nextStart
        }

        guard allItems.count == expectedTotalSize else { throw PlexAPIError.invalidResponse }
        return allItems
    }

    /// Get library sections
    public func getLibrarySections() async throws -> [PlexLibrarySection] {
        try await mediaContainerItems(path: "/library/sections")
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
        try await getArtists(sectionKey: sectionKey, limit: nil)
    }

    /// Get artists in a library section with an optional Plex container cap.
    public func getArtists(sectionKey: String, limit: Int?) async throws -> [PlexArtist] {
        guard let limit else {
            return try await getPagedSectionItems(
                sectionKey: sectionKey,
                baseQuery: ["type": "8"]
            )
        }
        var query = ["type": "8"]
        query["X-Plex-Container-Start"] = "0"
        query["X-Plex-Container-Size"] = String(limit)
        return try await mediaContainerItems(path: "/library/sections/\(sectionKey)/all", query: query)
    }

    /// Get artists added or updated after a specific timestamp (incremental sync)
    public func getArtists(sectionKey: String, addedAfter timestamp: TimeInterval) async throws -> [PlexArtist] {
        let unixTime = Int(timestamp)
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "8", "addedAt>": String(unixTime)]
        )
    }

    /// Get artists updated after a specific timestamp (incremental sync)
    public func getArtists(sectionKey: String, updatedAfter timestamp: TimeInterval) async throws -> [PlexArtist] {
        let unixTime = Int(timestamp)
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "8", "updatedAt>": String(unixTime)]
        )
    }

    /// Get all albums in a library section
    public func getAlbums(sectionKey: String) async throws -> [PlexAlbum] {
        try await getAlbums(sectionKey: sectionKey, limit: nil)
    }

    /// Get albums in a library section with an optional Plex container cap.
    public func getAlbums(sectionKey: String, limit: Int?) async throws -> [PlexAlbum] {
        guard let limit else {
            return try await getPagedSectionItems(
                sectionKey: sectionKey,
                baseQuery: ["type": "9"]
            )
        }
        var query = ["type": "9"]
        query["X-Plex-Container-Start"] = "0"
        query["X-Plex-Container-Size"] = String(limit)
        return try await mediaContainerItems(path: "/library/sections/\(sectionKey)/all", query: query)
    }

    /// Get albums added or updated after a specific timestamp (incremental sync)
    public func getAlbums(sectionKey: String, addedAfter timestamp: TimeInterval) async throws -> [PlexAlbum] {
        let unixTime = Int(timestamp)
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "9", "addedAt>": String(unixTime)]
        )
    }

    /// Get albums updated after a specific timestamp (incremental sync)
    public func getAlbums(sectionKey: String, updatedAfter timestamp: TimeInterval) async throws -> [PlexAlbum] {
        let unixTime = Int(timestamp)
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "9", "updatedAt>": String(unixTime)]
        )
    }

    /// Get albums by an artist
    public func getArtistAlbums(artistKey: String) async throws -> [PlexAlbum] {
        try await mediaContainerItems(path: "/library/metadata/\(artistKey)/children")
    }

    /// Get all albums credited to an artist within a library section.
    ///
    /// Plex's artist children endpoint can omit single-track releases that still belong to
    /// the artist. The section-level album query returns those releases when filtering by
    /// `artist.title`, while still returning standard albums.
    public func getArtistAlbums(sectionKey: String, artistTitle: String) async throws -> [PlexAlbum] {
        try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "9",
                "artist.title": artistTitle
            ]
        )
    }

    /// Get album format filter values exposed by a music library, e.g. Album, EP, Single.
    public func getAlbumFormatFilters(sectionKey: String) async throws -> [PlexLibraryFilterValue] {
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/format",
            query: ["type": "9"]
        )
    }

    /// Get all albums constrained to a specific Plex album format.
    public func getAlbums(sectionKey: String, formatKey: String) async throws -> [PlexAlbum] {
        try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "9",
                "format": formatKey
            ]
        )
    }

    /// Get albums credited to an artist and constrained to a specific Plex album format.
    public func getArtistAlbums(sectionKey: String, artistTitle: String, formatKey: String) async throws -> [PlexAlbum] {
        try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "9",
                "artist.title": artistTitle,
                "format": formatKey
            ]
        )
    }

    /// Get all tracks in a library section
    public func getTracks(sectionKey: String) async throws -> [PlexTrack] {
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media"
            ]
        )
    }

    /// Get the number of tracks in a library section without fetching track metadata.
    public func getTrackCount(sectionKey: String) async throws -> Int? {
        let data = try await serverRequest(
            path: "/library/sections/\(sectionKey)/all",
            query: [
                "type": "10",
                "X-Plex-Container-Start": "0",
                "X-Plex-Container-Size": "0"
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexInventoryItem>.self,
            from: data
        )
        return container.mediaContainer.totalSize ?? container.mediaContainer.size
    }

    /// Get tracks added or updated after a specific timestamp (incremental sync)
    public func getTracks(sectionKey: String, addedAfter timestamp: TimeInterval) async throws -> [PlexTrack] {
        let unixTime = Int(timestamp)
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media",
                "addedAt>": String(unixTime)
            ]
        )
    }

    /// Get tracks updated after a specific timestamp (incremental sync)
    public func getTracks(sectionKey: String, updatedAfter timestamp: TimeInterval) async throws -> [PlexTrack] {
        let unixTime = Int(timestamp)
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media",
                "updatedAt>": String(unixTime)
            ]
        )
    }

    /// Get tracks rated after a specific timestamp (for syncing rating changes from other devices)
    public func getTracks(sectionKey: String, ratedAfter timestamp: TimeInterval) async throws -> [PlexTrack] {
        let unixTime = Int(timestamp)
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "10",
                "includeMedia": "1",
                "includeElements": "Media",
                "lastRatedAt>": String(unixTime)
            ]
        )
    }

    /// Get tracks in an album
    public func getAlbumTracks(albumKey: String) async throws -> [PlexTrack] {
        return try await mediaContainerItems(
            path: "/library/metadata/\(albumKey)/children",
            query: [
                "includeMedia": "1",
                "includeElements": "Media"
            ]
        )
    }

    /// Get all tracks by an artist
    public func getArtistTracks(artistKey: String) async throws -> [PlexTrack] {
        try await mediaContainerItems(
            path: "/library/metadata/\(artistKey)/allLeaves",
            query: [
                "includeMedia": "1",
                "includeElements": "Media"
            ]
        )
    }

    /// Get genres in a library section
    public func getGenres(sectionKey: String) async throws -> [PlexGenre] {
        try await mediaContainerItems(path: "/library/sections/\(sectionKey)/genre")
    }

    /// Get all artist ratingKeys in a library section (minimal response)
    /// Uses includeFields=ratingKey to reduce response size significantly
    public func getArtistInventory(sectionKey: String) async throws -> [PlexInventoryItem] {
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "8",
                "includeFields": "ratingKey",
                "excludeElements": "Media,Genre,Country,Guid,Rating,Collection,Director,Writer,Role"
            ]
        )
    }

    /// Get all album ratingKeys in a library section (minimal response)
    public func getAlbumInventory(sectionKey: String) async throws -> [PlexInventoryItem] {
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "9",
                "includeFields": "ratingKey",
                "excludeElements": "Media,Genre,Country,Guid,Rating,Collection,Director,Writer,Role"
            ]
        )
    }

    /// Get all track ratingKeys in a library section (minimal response)
    public func getTrackInventory(sectionKey: String) async throws -> [PlexInventoryItem] {
        return try await getPagedSectionItems(
            sectionKey: sectionKey,
            baseQuery: [
                "type": "10",
                "includeFields": "ratingKey",
                "excludeElements": "Media,Genre,Mood,Guid,Rating"
            ]
        )
    }

    /// Get moods in a library section
    public func getMoods(sectionKey: String) async throws -> [PlexMood] {
        try await mediaContainerItems(path: "/library/sections/\(sectionKey)/mood")
    }

    /// Get tracks by genre
    public func getTracksByGenre(sectionKey: String, genreKey: String) async throws -> [PlexTrack] {
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "10", "genre": genreKey]
        )
    }

    /// Get tracks by mood
    public func getTracksByMood(sectionKey: String, moodKey: String) async throws -> [PlexTrack] {
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/all",
            query: ["type": "10", "mood": moodKey]
        )
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
        try await mediaContainerItems(path: hubKey)
    }

    /// Search library
    public func search(query: String, sectionKey: String) async throws -> [PlexTrack] {
        return try await mediaContainerItems(
            path: "/library/sections/\(sectionKey)/search",
            query: ["type": "10", "query": query]
        )
    }

    /// Rate a metadata item (0 = no rating, 2 = 1 star, 4 = 2 stars, ..., 10 = 5 stars)
    /// Pass nil or 0 to remove rating
    public func rateItem(ratingKey: String, rating: Int?) async throws {
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
