import Foundation
#if os(iOS)
import UIKit
#endif

public enum PlexAPIError: Error, LocalizedError {
    case notAuthenticated
    case noServerSelected
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Plex"
        case .noServerSelected:
            return "No server selected"
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

public struct PlexServerConnection: Sendable {
    public let url: String
    public let alternativeURLs: [String]  // Additional connection URLs for failover
    public let endpoints: [PlexEndpointDescriptor]
    public let selectionPolicy: ConnectionSelectionPolicy
    public let allowInsecurePolicy: AllowInsecureConnectionsPolicy
    public let token: String
    public let identifier: String
    public let name: String

    public init(
        url: String,
        alternativeURLs: [String] = [],
        endpoints: [PlexEndpointDescriptor] = [],
        selectionPolicy: ConnectionSelectionPolicy = .plexSpecBalanced,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy = .sameNetwork,
        token: String,
        identifier: String,
        name: String
    ) {
        self.url = url
        self.alternativeURLs = alternativeURLs
        if endpoints.isEmpty {
            let primary = PlexEndpointDescriptor(url: url, local: false, relay: false)
            let alternatives = alternativeURLs.map { PlexEndpointDescriptor(url: $0, local: false, relay: false) }
            self.endpoints = [primary] + alternatives
        } else {
            self.endpoints = endpoints
        }
        self.selectionPolicy = selectionPolicy
        self.allowInsecurePolicy = allowInsecurePolicy
        self.token = token
        self.identifier = identifier
        self.name = name
    }
    
    /// All available connection URLs (primary + alternatives)
    public var allURLs: [String] {
        [url] + alternativeURLs
    }
}

public struct PlexLibrarySelection: Sendable {
    public let key: String
    public let title: String

    public init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

public actor PlexAPIClient {
    private let session: URLSession
    private let keychain: KeychainServiceProtocol
    private let clientIdentifier: String
    private let productName: String
    private let productVersion: String
    private let platformName: String
    private let deviceName: String
    private let failoverManager: ConnectionFailoverManager

    private let serverConnection: PlexServerConnection
    private let selectedLibrary: PlexLibrarySelection?
    private var currentServerURL: String  // The currently active server URL

    private static let plexTVBaseURL = "https://plex.tv"

    /// Initialize with a direct server connection
    public init(
        connection: PlexServerConnection,
        librarySelection: PlexLibrarySelection? = nil,
        keychain: KeychainServiceProtocol = KeychainService.shared,
        failoverManager: ConnectionFailoverManager = ConnectionFailoverManager(),
        productName: String = "Ensemble",
        productVersion: String = "1.0"
    ) {
        self.keychain = keychain
        self.serverConnection = connection
        self.selectedLibrary = librarySelection
        self.currentServerURL = connection.url
        self.failoverManager = failoverManager
        self.productName = productName
        self.productVersion = productVersion
        #if os(iOS)
        self.platformName = "iOS"
        self.deviceName = UIDevice.current.name
        #elseif os(macOS)
        self.platformName = "macOS"
        self.deviceName = Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        self.platformName = "watchOS"
        self.deviceName = "Apple Watch"
        #else
        self.platformName = "Unknown"
        self.deviceName = "Unknown Device"
        #endif

        if let existingId = try? keychain.get(KeychainKey.plexClientIdentifier) {
            self.clientIdentifier = existingId
        } else {
            let newId = UUID().uuidString
            // try? is unavoidable in init (can't throw); log if it fails so we notice in debug builds
            if (try? keychain.save(newId, forKey: KeychainKey.plexClientIdentifier)) == nil {
                #if DEBUG
                EnsembleLogger.debug("⚠️ [PlexAPIClient] Failed to persist client identifier to keychain")
                #endif
            }
            self.clientIdentifier = newId
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15  // Reduced from 30s for faster failover on remote networks
        config.timeoutIntervalForResource = 120  // Keep resource timeout longer for large responses
        self.session = URLSession(configuration: config)
        
        // Log connection details for debugging
        let isHTTPS = connection.url.lowercased().hasPrefix("https://")
        let altCount = connection.alternativeURLs.count
        #if DEBUG
        EnsembleLogger.debug("🔌 PlexAPIClient initialized")
        EnsembleLogger.debug("   Primary URL: \(connection.url) (HTTPS: \(isHTTPS))")
        EnsembleLogger.debug("   Alternative URLs: \(altCount)")
        #endif
        for (index, altURL) in connection.alternativeURLs.enumerated() {
            let altHTTPS = altURL.lowercased().hasPrefix("https://")
            #if DEBUG
            EnsembleLogger.debug("   [\(index + 1)] \(altURL) (HTTPS: \(altHTTPS))")
            #endif
        }
    }

    // MARK: - Server Connection

    public func getServerConnection() -> PlexServerConnection {
        serverConnection
    }

    // MARK: - Library Selection

    public func getLibrarySelection() -> PlexLibrarySelection? {
        selectedLibrary
    }

    /// Get all music library sections
    public func getMusicLibrarySections() async throws -> [PlexLibrarySection] {
        let sections = try await getLibrarySections()
        return sections.filter { $0.isMusicLibrary }
    }

    // MARK: - Plex.tv API (for auth flow - takes token as parameter)

    /// Get user's servers/resources
    public func getResources(token: String) async throws -> [PlexDevice] {
        let request = try makeResourcesRequest(token: token)

        let (data, _) = try await performRequest(request)
        let devices = try JSONDecoder().decode([PlexDevice].self, from: data)
        return devices.filter { $0.isServer }
    }

    /// Get user info
    public func getUserInfo(token: String) async throws -> PlexUser {
        guard let url = URL(string: "\(Self.plexTVBaseURL)/api/v2/user") else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addPlexHeaders(to: &request, token: token)

        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode(PlexUser.self, from: data)
    }

    // MARK: - Server API

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
        if let selected = selectedLibrary {
            if let match = musicSections.first(where: { $0.key == selected.key }) {
                return match
            }
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
        // Try different parameters that might include Media array
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

    /// Get a single track
    public func getTrack(trackKey: String) async throws -> PlexTrack? {
        // Fetch without extra parameters - single track fetches typically include Media
        let data = try await serverRequest(
            path: "/library/metadata/\(trackKey)"
        )
        
        // Debug: Print raw JSON to see what Plex is returning
        if let jsonString = String(data: data, encoding: .utf8) {
            #if DEBUG
            EnsembleLogger.debug("🔍 Raw JSON response (first 500 chars): \(String(jsonString.prefix(500)))")
            #endif
        }
        
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        let track = container.mediaContainer.items.first
        
        if let track = track {
            #if DEBUG
            EnsembleLogger.debug("🔍 getTrack - media count: \(track.media?.count ?? 0)")
            #endif
            if let media = track.media?.first {
                #if DEBUG
                EnsembleLogger.debug("🔍 getTrack - part count: \(media.part?.count ?? 0)")
                #endif
                if let part = media.part?.first {
                    #if DEBUG
                    EnsembleLogger.debug("🔍 getTrack - part key: \(part.key ?? "nil")")
                    EnsembleLogger.debug("🔍 getTrack - part file: \(part.file ?? "nil")")
                    #endif
                }
            }
        }
        
        return track
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

    // MARK: - Lightweight Inventory (for orphan detection)

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

    /// Get audio playlists
    public func getPlaylists() async throws -> [PlexPlaylist] {
        let data = try await serverRequest(path: "/playlists", query: ["playlistType": "audio"])
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexPlaylist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get playlist inventory (just ratingKeys) for orphan detection
    public func getPlaylistInventory() async throws -> [PlexInventoryItem] {
        let data = try await serverRequest(
            path: "/playlists",
            query: [
                "playlistType": "audio",
                "includeFields": "ratingKey",
                "excludeElements": "Media"
            ]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexInventoryItem>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get playlists added after a specific timestamp (incremental sync)
    public func getPlaylists(addedAfter timestamp: TimeInterval) async throws -> [PlexPlaylist] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/playlists",
            query: ["playlistType": "audio", "addedAt>=": String(unixTime)]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexPlaylist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get playlists updated after a specific timestamp (incremental sync)
    public func getPlaylists(updatedAfter timestamp: TimeInterval) async throws -> [PlexPlaylist] {
        let unixTime = Int(timestamp)
        let data = try await serverRequest(
            path: "/playlists",
            query: ["playlistType": "audio", "updatedAt>=": String(unixTime)]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexPlaylist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get playlist tracks
    public func getPlaylistTracks(playlistKey: String) async throws -> [PlexTrack] {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getPlaylistTracks() called")
        EnsembleLogger.debug("  - Playlist key: \(playlistKey)")
        #endif
        
        #if DEBUG
        EnsembleLogger.debug("🔄 Fetching playlist items from /playlists/\(playlistKey)/items...")
        #endif
        let data = try await serverRequest(path: "/playlists/\(playlistKey)/items")
        #if DEBUG
        EnsembleLogger.debug("✅ Got response data (\(data.count) bytes)")
        #endif
        
        #if DEBUG
        EnsembleLogger.debug("🔄 Decoding playlist tracks...")
        #endif
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        #if DEBUG
        EnsembleLogger.debug("✅ Got \(container.mediaContainer.items.count) playlist tracks")
        #endif
        return container.mediaContainer.items
    }

    /// Create a new audio playlist
    /// - Parameters:
    ///   - title: Playlist title
    ///   - trackRatingKeys: Rating keys to include
    ///   - serverIdentifier: Target Plex server identifier
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
    
    // MARK: - Hubs (Home Screen Content)
    
    /// Get all hubs for a library section (Recently Added, Recently Played, etc.)
    public func getHubs(sectionKey: String) async throws -> [PlexHub] {
        // Adding count and includeLibrary ensures we get items back in the Metadata array
        let data = try await serverRequest(
            path: "/hubs/sections/\(sectionKey)",
            query: [
                "count": "12",
                "includeLibrary": "1",
                "includeExternalMedia": "1",
                "excludeFields": "summary" // Reduce payload size
            ]
        )
        
        // Log raw JSON for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            #if DEBUG
            EnsembleLogger.debug("🔍 Raw Hubs JSON (Section \(sectionKey)): \(jsonString.prefix(2000))")
            #endif
        }
        
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHub>.self,
            from: data
        )
        let hubs = container.mediaContainer.items
        #if DEBUG
        EnsembleLogger.debug("🏠 Decoded \(hubs.count) hubs from Section \(sectionKey)")
        #endif
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
        
        // Log raw JSON for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            #if DEBUG
            EnsembleLogger.debug("🔍 Raw Global Hubs JSON: \(jsonString.prefix(2000))")
            #endif
        }
        
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHub>.self,
            from: data
        )
        let hubs = container.mediaContainer.items
        #if DEBUG
        EnsembleLogger.debug("🏠 Decoded \(hubs.count) global hubs")
        #endif
        return hubs
    }
    
    /// Get items for a specific hub
    public func getHubItems(hubKey: String) async throws -> [PlexHubMetadata] {
        let data = try await serverRequest(path: hubKey)
        
        // Hub items are returned as metadata
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

        // Validate rating is in range (0-10, even numbers only for stars)
        guard ratingValue >= 0 && ratingValue <= 10 else {
            throw PlexAPIError.invalidURL
        }

        let path = "/:/rate"
        let query = [
            "key": ratingKey,
            "identifier": "com.plexapp.plugins.library",
            "rating": String(ratingValue)
        ]

        _ = try await serverRequestPUT(path: path, query: query)
    }

    // MARK: - Timeline & Scrobbling

    /// Report playback timeline to Plex server
    /// This updates the server with current playback state and position
    /// - Parameters:
    ///   - ratingKey: The track's rating key
    ///   - key: The track's key path (e.g., "/library/metadata/12345")
    ///   - state: Playback state ("playing", "paused", or "stopped")
    ///   - time: Current playback time in milliseconds
    ///   - duration: Total track duration in milliseconds
    public func reportTimeline(
        ratingKey: String,
        key: String,
        state: String,
        time: Int,
        duration: Int
    ) async throws {
        let path = "/:/timeline"
        let query = [
            "ratingKey": ratingKey,
            "key": key,
            "state": state,
            "time": String(time),
            "duration": String(duration),
            "playQueueItemID": ratingKey  // Use ratingKey as playQueueItemID
        ]

        _ = try await serverRequest(path: path, query: query)
        #if DEBUG
        EnsembleLogger.debug("📊 Timeline reported: \(state) at \(time)ms / \(duration)ms for track \(ratingKey)")
        #endif
    }

    /// Scrobble a track (mark as played)
    /// This should be called when a track reaches ~90% completion
    /// Updates play count and "last played" timestamp on the server
    /// - Parameter ratingKey: The track's rating key
    public func scrobble(ratingKey: String) async throws {
        let path = "/:/scrobble"
        let query = [
            "key": ratingKey,
            "identifier": "com.plexapp.plugins.library"
        ]

        _ = try await serverRequest(path: path, query: query)
        #if DEBUG
        EnsembleLogger.debug("✅ Scrobbled track: \(ratingKey)")
        #endif
    }

    // MARK: - URL Generation

    /// Generate streaming URL for a track using its stream key
    public func getStreamURL(trackKey: String?) throws -> URL {
        guard let partKey = trackKey, !partKey.isEmpty else {
            #if DEBUG
            EnsembleLogger.debug("❌ PlexAPIClient: trackKey is nil or empty")
            #endif
            throw PlexAPIError.invalidURL
        }

        #if DEBUG
        EnsembleLogger.debug("🔍 PlexAPIClient: Building stream URL with partKey: \(partKey)")
        EnsembleLogger.debug("🔍 PlexAPIClient: Current server URL: \(currentServerURL)")
        #endif

        guard var components = URLComponents(string: currentServerURL) else {
            #if DEBUG
            EnsembleLogger.debug("❌ PlexAPIClient: Failed to create URLComponents from current server URL")
            #endif
            throw PlexAPIError.invalidURL
        }
        
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            #if DEBUG
            EnsembleLogger.debug("❌ PlexAPIClient: Failed to construct final URL")
            EnsembleLogger.debug("❌ PlexAPIClient: Components - path: \(components.path), host: \(components.host ?? "nil")")
            #endif
            throw PlexAPIError.invalidURL
        }

        #if DEBUG
        EnsembleLogger.debug("✅ PlexAPIClient: Successfully created stream URL: \(url)")
        #endif
        return url
    }

    /// Generate streaming URL for a track
    public func getStreamURL(for track: PlexTrack) throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🔍 PlexAPIClient.getStreamURL(for track): \(track.title)")
        EnsembleLogger.debug("🔍 Track ratingKey: \(track.ratingKey)")
        EnsembleLogger.debug("🔍 Track media count: \(track.media?.count ?? 0)")
        #endif

        if let media = track.media?.first {
            #if DEBUG
            EnsembleLogger.debug("🔍 First media - parts count: \(media.part?.count ?? 0)")
            #endif
            if let part = media.part?.first {
                #if DEBUG
                EnsembleLogger.debug("🔍 First part key: \(part.key ?? "nil")")
                #endif
            } else {
                #if DEBUG
                EnsembleLogger.debug("❌ No parts in media")
                #endif
            }
        } else {
            #if DEBUG
            EnsembleLogger.debug("❌ No media array in track")
            #endif
        }

        guard let partKey = track.media?.first?.part?.first?.key else {
            #if DEBUG
            EnsembleLogger.debug("❌ Cannot extract part key from track")
            #endif
            throw PlexAPIError.invalidURL
        }

        #if DEBUG
        EnsembleLogger.debug("🔍 Building URL with partKey: \(partKey)")
        EnsembleLogger.debug("🔍 Current server URL: \(currentServerURL)")
        #endif
        guard var components = URLComponents(string: currentServerURL) else {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to create URLComponents from current server URL")
            #endif
            throw PlexAPIError.invalidURL
        }
        
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to construct final URL")
            #endif
            throw PlexAPIError.invalidURL
        }

        #if DEBUG
        EnsembleLogger.debug("✅ Successfully created stream URL: \(url)")
        #endif
        return url
    }

    /// Generate artwork URL
    public func getArtworkURL(path: String?, size: Int = 300) throws -> URL? {
        guard let path = path else { return nil }

        guard var components = URLComponents(string: currentServerURL) else {
            return nil
        }
        
        components.path = "/photo/:/transcode"
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: String(size)),
            URLQueryItem(name: "height", value: String(size)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token)
        ]

        return components.url
    }
    
    /// Fetch loudness timeline data for waveform visualization
    /// Returns nil if the server hasn't performed sonic analysis on this track yet
    /// - Parameters:
    ///   - streamId: The audio stream ID (from PlexTrack.media[0].part[0].stream[0].id where streamType == 2)
    ///   - subsample: Number of loudness samples to return (default: 128, Plex supports up to ~200)
    public func getLoudnessTimeline(forStreamId streamId: Int, subsample: Int = 128) async throws -> PlexLoudnessTimeline? {
        #if DEBUG
        EnsembleLogger.debug("🎵 Fetching loudness timeline for stream ID: \(streamId)")
        #endif

        // Correct Plex API endpoint: /library/streams/{stream_id}/levels?subsample={count}
        // This returns loudness level data for waveform visualization
        let path = "/library/streams/\(streamId)/levels"
        let query = ["subsample": String(subsample)]

        do {
            let data = try await serverRequest(path: path, query: query)

            // Debug: Print raw response to understand format
            if let responseString = String(data: data, encoding: .utf8) {
                #if DEBUG
                EnsembleLogger.debug("🔍 Raw loudness response (first 500 chars): \(String(responseString.prefix(500)))")
                #endif
            }

            let timeline = try JSONDecoder().decode(PlexLoudnessTimeline.self, from: data)

            if let count = timeline.loudness?.count {
                #if DEBUG
                EnsembleLogger.debug("✅ Retrieved \(count) loudness samples for stream \(streamId)")
                #endif
            } else {
                #if DEBUG
                EnsembleLogger.debug("⚠️ No loudness data available for stream \(streamId)")
                #endif
            }

            return timeline
        } catch {
            // If the endpoint doesn't exist (404), the server hasn't analyzed this track yet
            // This is normal and not an error condition
            #if DEBUG
            EnsembleLogger.debug("ℹ️ Loudness timeline not available for stream \(streamId): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Radio & Recommendations

    /// Get sonically similar tracks for radio recommendations
    /// Returns nil if sonic analysis not performed or Plex Pass not active
    /// - Parameters:
    ///   - ratingKey: The track's rating key to find similar tracks for
    ///   - limit: Maximum number of similar tracks to return (default: 50)
    ///   - maxDistance: Maximum sonic distance (0.0-1.0, default: 0.25). Lower = more similar
    public func getSimilarTracks(
        ratingKey: String,
        limit: Int = 50,
        maxDistance: Double = 0.25
    ) async throws -> [PlexTrack]? {
        #if DEBUG
        EnsembleLogger.debug("\n🎵 PlexAPIClient.getSimilarTracks()")
        EnsembleLogger.debug("  - ratingKey: \(ratingKey)")
        EnsembleLogger.debug("  - limit: \(limit)")
        EnsembleLogger.debug("  - maxDistance: \(maxDistance)")
        #endif

        let path = "/library/metadata/\(ratingKey)/nearest"
        let query = [
            "limit": String(limit),
            "maxDistance": String(maxDistance)
        ]
        #if DEBUG
        EnsembleLogger.debug("  - path: \(path)")
        EnsembleLogger.debug("  - query: \(query)")
        #endif

        do {
            #if DEBUG
            EnsembleLogger.debug("🔄 Making serverRequest...")
            #endif
            let data = try await serverRequest(path: path, query: query)
            #if DEBUG
            EnsembleLogger.debug("✅ Received response data (\(data.count) bytes)")
            #endif
            
            #if DEBUG
            EnsembleLogger.debug("🔄 Decoding JSON...")
            #endif
            let container = try JSONDecoder().decode(
                PlexMediaContainer<PlexTrack>.self,
                from: data
            )
            let tracks = container.mediaContainer.items
            #if DEBUG
            EnsembleLogger.debug("✅ Successfully decoded \(tracks.count) PlexTrack objects")
            #endif
            
            if tracks.isEmpty {
                #if DEBUG
                EnsembleLogger.debug("⚠️ WARNING: API returned empty track list (no sonic analysis available)")
                #endif
            } else {
                // Log first few results as confirmation
                for track in tracks.prefix(3) {
                    #if DEBUG
                    EnsembleLogger.debug("  ✅ Recommended: \(track.title) by \(track.grandparentTitle ?? "Unknown")")
                    #endif
                }
                if tracks.count > 3 {
                    #if DEBUG
                    EnsembleLogger.debug("  ... and \(tracks.count - 3) more tracks")
                    #endif
                }
            }
            
            return tracks
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Error in getSimilarTracks:")
            EnsembleLogger.debug("   Type: \(type(of: error))")
            EnsembleLogger.debug("   Message: \(error.localizedDescription)")
            #endif
            
            let nsError = error as NSError
            #if DEBUG
            EnsembleLogger.debug("   NSError domain: \(nsError.domain)")
            EnsembleLogger.debug("   Code: \(nsError.code)")
            EnsembleLogger.debug("   UserInfo: \(nsError.userInfo)")
            #endif
            
            // Check if it's a 404 (no sonic analysis)
            if let urlError = error as? URLError, urlError.code == .fileDoesNotExist {
                #if DEBUG
                EnsembleLogger.debug("   → This is a 404: No sonic analysis available for this track")
                #endif
            }
            
            return nil
        }
    }

    /// Get artist radio station as a playlist
    /// Returns nil if artist radio not available or Plex Pass not active
    /// - Parameter artistKey: The artist's rating key
    public func getArtistRadioStation(artistKey: String) async throws -> PlexPlaylist? {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getArtistRadioStation() called")
        EnsembleLogger.debug("  - Artist key: \(artistKey)")
        EnsembleLogger.debug("🔄 Fetching artist radio station from Plex...")
        #endif

        let path = "/library/metadata/\(artistKey)"
        let query = ["includeStations": "1"]
        #if DEBUG
        EnsembleLogger.debug("  - Path: \(path)")
        EnsembleLogger.debug("  - Query: \(query)")
        #endif

        do {
            #if DEBUG
            EnsembleLogger.debug("🔄 Making serverRequest...")
            #endif
            let data = try await serverRequest(path: path, query: query)
            #if DEBUG
            EnsembleLogger.debug("✅ Got response data (\(data.count) bytes)")
            #endif

            // The response includes a Stations container within the metadata
            // We need to parse it to extract the playlist
            #if DEBUG
            EnsembleLogger.debug("🔄 Decoding response...")
            #endif
            let container = try JSONDecoder().decode(
                PlexMediaContainer<PlexPlaylist>.self,
                from: data
            )
            #if DEBUG
            EnsembleLogger.debug("✅ Decoded successfully, got \(container.mediaContainer.items.count) items")
            #endif

            // Filter for station-type playlists
            let station = container.mediaContainer.items.first
            if let station = station {
                #if DEBUG
                EnsembleLogger.debug("✅ Found artist radio station: \(station.title) (key: \(station.ratingKey))")
                #endif
            } else {
                #if DEBUG
                EnsembleLogger.debug("ℹ️ No artist radio station found for \(artistKey)")
                #endif
            }
            return station
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Artist radio not available for \(artistKey): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Get album radio station as a playlist
    /// Returns nil if album radio not available or Plex Pass not active
    /// - Parameter albumKey: The album's rating key
    public func getAlbumRadioStation(albumKey: String) async throws -> PlexPlaylist? {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getAlbumRadioStation() called")
        EnsembleLogger.debug("  - Album key: \(albumKey)")
        EnsembleLogger.debug("🔄 Fetching album radio station from Plex...")
        #endif

        let path = "/library/metadata/\(albumKey)"
        let query = ["includeStations": "1"]
        #if DEBUG
        EnsembleLogger.debug("  - Path: \(path)")
        EnsembleLogger.debug("  - Query: \(query)")
        #endif

        do {
            #if DEBUG
            EnsembleLogger.debug("🔄 Making serverRequest...")
            #endif
            let data = try await serverRequest(path: path, query: query)
            #if DEBUG
            EnsembleLogger.debug("✅ Got response data (\(data.count) bytes)")
            #endif

            #if DEBUG
            EnsembleLogger.debug("🔄 Decoding response...")
            #endif
            let container = try JSONDecoder().decode(
                PlexMediaContainer<PlexPlaylist>.self,
                from: data
            )
            #if DEBUG
            EnsembleLogger.debug("✅ Decoded successfully, got \(container.mediaContainer.items.count) items")
            #endif

            let station = container.mediaContainer.items.first
            if let station = station {
                #if DEBUG
                EnsembleLogger.debug("✅ Found album radio station: \(station.title) (key: \(station.ratingKey))")
                #endif
            } else {
                #if DEBUG
                EnsembleLogger.debug("ℹ️ No album radio station found for \(albumKey)")
                #endif
            }
            return station
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Album radio not available for \(albumKey): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Connection Management
    
    /// Attempt to find a policy-compliant working connection if current one fails.
    private func attemptFailover() async throws -> ConnectionSelectionResult {
        #if DEBUG
        EnsembleLogger.debug("🔄 Attempting connection failover...")
        #endif

        let selection = await failoverManager.findBestConnection(
            endpoints: serverConnection.endpoints,
            token: serverConnection.token,
            selectionPolicy: serverConnection.selectionPolicy,
            allowInsecure: serverConnection.allowInsecurePolicy
        )

        guard let endpoint = selection.selected else {
            #if DEBUG
            EnsembleLogger.debug(
                "❌ No working connections found (probes=\(selection.probes.count), skippedInsecure=\(selection.skippedInsecureCount))"
            )
            #endif
            throw PlexAPIError.networkError(
                NSError(
                    domain: "PlexAPIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "All server connections failed"]
                )
            )
        }

        currentServerURL = endpoint.url
        #if DEBUG
        EnsembleLogger.debug("✅ Found working connection: \(endpoint.url)")
        #endif
        return selection
    }
    
    /// Get the current active server URL
    public func getCurrentServerURL() -> String {
        currentServerURL
    }

    /// Update the current server URL (e.g., from external health checks)
    /// This allows proactive failover based on network changes
    public func updateCurrentServerURL(_ url: String) {
        #if DEBUG
        EnsembleLogger.debug("🔄 PlexAPIClient: Updating current server URL to: \(url)")
        #endif
        currentServerURL = url
    }

    /// Proactively test and update to the best available connection.
    @discardableResult
    public func refreshConnection() async throws -> ConnectionRefreshResult {
        #if DEBUG
        EnsembleLogger.debug("🔄 PlexAPIClient: Refreshing connection...")
        #endif
        let previousURL = currentServerURL
        let selection = try await attemptFailover()
        guard let selected = selection.selected else {
            throw PlexAPIError.noServerSelected
        }
        let outcome: ConnectionRefreshResult.RefreshOutcome = (selected.url == previousURL) ? .unchanged : .switched
        #if DEBUG
        EnsembleLogger.debug(
            "✅ PlexAPIClient: Connection refreshed host=\(selected.safeHostDescription) outcome=\(outcome.rawValue)"
        )
        #endif
        return ConnectionRefreshResult(
            outcome: outcome,
            selectedEndpoint: selected,
            probeCount: selection.probes.count,
            skippedInsecureCount: selection.skippedInsecureCount,
            reusedPreferredPath: selection.reusedPreferredPath
        )
    }

    // MARK: - Private Methods

    private func serverRequest(path: String, query: [String: String] = [:]) async throws -> Data {
        // Try with current URL first
        do {
            return try await performServerRequest(url: currentServerURL, path: path, query: query)
        } catch {
            // Log the actual error for debugging
            #if DEBUG
            EnsembleLogger.debug("❌ Request failed: \(error)")
            #endif
            if let urlError = error as? URLError {
                #if DEBUG
                EnsembleLogger.debug("   URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                #endif
            }

            // Fail over only for transport/connectivity failures.
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Attempting failover to alternative URLs...")
                #endif
                _ = try await attemptFailover()
                // Retry with new URL
                return try await performServerRequest(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }
    
    private func performServerRequest(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        var components = try makeURLComponents(for: url)
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        addPlexHeaders(to: &request, token: serverConnection.token)

        // Log request for debugging (only show host and path, not full URL with token)
        let isHTTPS = url.lowercased().hasPrefix("https://")
        let urlHost = URLComponents(string: url)?.host ?? "unknown"
        #if DEBUG
        EnsembleLogger.debug("📡 Request: \(request.httpMethod ?? "GET") \(urlHost)\(path) (HTTPS: \(isHTTPS))")
        #endif

        let (data, _) = try await performRequest(request)
        return data
    }
    
    private func serverRequestPUT(path: String, query: [String: String] = [:]) async throws -> Data {
        // Try with current URL first
        do {
            return try await performServerRequestPUT(url: currentServerURL, path: path, query: query)
        } catch {
            // If request fails and we have alternative URLs, attempt failover
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                #if DEBUG
                EnsembleLogger.debug("⚠️ PUT request failed with current URL, attempting failover...")
                #endif
                _ = try await attemptFailover()
                // Retry with new URL
                return try await performServerRequestPUT(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }
    
    private func performServerRequestPUT(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        var components = try makeURLComponents(for: url)
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        addPlexHeaders(to: &request, token: serverConnection.token)

        let (data, _) = try await performRequest(request)
        return data
    }

    private func serverRequestPOST(path: String, query: [String: String] = [:]) async throws -> Data {
        do {
            return try await performServerRequestPOST(url: currentServerURL, path: path, query: query)
        } catch {
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                #if DEBUG
                EnsembleLogger.debug("⚠️ POST request failed with current URL, attempting failover...")
                #endif
                _ = try await attemptFailover()
                return try await performServerRequestPOST(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }

    private func performServerRequestPOST(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        var components = try makeURLComponents(for: url)
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        addPlexHeaders(to: &request, token: serverConnection.token)

        let (data, _) = try await performRequest(request)
        return data
    }

    private func serverRequestDELETE(path: String, query: [String: String] = [:]) async throws -> Data {
        do {
            return try await performServerRequestDELETE(url: currentServerURL, path: path, query: query)
        } catch {
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                #if DEBUG
                EnsembleLogger.debug("⚠️ DELETE request failed with current URL, attempting failover...")
                #endif
                _ = try await attemptFailover()
                return try await performServerRequestDELETE(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }

    private func performServerRequestDELETE(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        let request = try makeServerRequest(url: url, method: "DELETE", path: path, query: query)
        let (data, _) = try await performRequest(request)
        return data
    }

    /// Build a server request with Plex auth headers and tokenized query.
    internal func makeServerRequest(
        url: String,
        method: String,
        path: String,
        query: [String: String] = [:]
    ) throws -> URLRequest {
        var components = try makeURLComponents(for: url)
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        addPlexHeaders(to: &request, token: serverConnection.token)
        return request
    }

    internal func makeResourcesRequest(token: String) throws -> URLRequest {
        guard let url = URL(string: "\(Self.plexTVBaseURL)/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1") else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addPlexHeaders(to: &request, token: token)
        return request
    }

    /// Build URL components safely from a server URL string.
    private func makeURLComponents(for url: String) throws -> URLComponents {
        guard let components = URLComponents(string: url) else {
            throw PlexAPIError.invalidURL
        }
        return components
    }

    private func shouldAttemptFailover(after error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .networkError, .invalidResponse:
                return true
            case .httpError, .decodingError, .invalidURL, .notAuthenticated, .noServerSelected:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed:
                return true
            case .cancelled:
                return false
            default:
                return false
            }
        }

        return false
    }

    internal func shouldAttemptFailoverForTesting(after error: Error) -> Bool {
        shouldAttemptFailover(after: error)
    }

    /// Build Plex metadata URI format used for playlist mutations.
    private func buildMetadataURI(serverIdentifier: String, ratingKeys: [String]) -> String {
        let keys = ratingKeys.joined(separator: ",")
        return "server://\(serverIdentifier)/com.plexapp.plugins.library/library/metadata/\(keys)"
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Check if the task is already cancelled before making the request
        if Task.isCancelled {
            #if DEBUG
            EnsembleLogger.debug("⚠️ Task was cancelled before request started!")
            #endif
            throw CancellationError()
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlexAPIError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return (data, httpResponse)
        } catch let error as PlexAPIError {
            throw error
        } catch {
            throw PlexAPIError.networkError(error)
        }
    }

    private func addPlexHeaders(to request: inout URLRequest, token: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(productVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(platformName, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue("controller", forHTTPHeaderField: "X-Plex-Provides")
    }
}
