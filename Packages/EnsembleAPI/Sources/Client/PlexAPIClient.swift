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

/// Streaming quality options matching the AppStorage settings in SettingsView
public enum StreamingQuality: String, Sendable {
    case original = "original"
    case high = "high"        // 320 kbps
    case medium = "medium"    // 192 kbps
    case low = "low"          // 128 kbps
}

/// Result of resolving how to stream a track — either a remote URL AVPlayer
/// can stream directly, or a local file that was fully downloaded (transcode).
public enum StreamResolution: Sendable {
    case directStream(URL)    // AVPlayer streams progressively from remote URL
    case downloadedFile(URL)  // Full file downloaded locally (transcode was needed)

    public var url: URL {
        switch self {
        case .directStream(let url), .downloadedFile(let url):
            return url
        }
    }
}

/// Parsed result from PMS's transcode decision endpoint.
public struct TranscodeDecisionResult: Sendable {
    public enum Decision: String, Sendable {
        case directplay, copy, transcode, unknown
    }

    public let decision: Decision
    /// Part key from the decision response (e.g. "/library/parts/8955/...")
    public let directStreamPartKey: String?
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
    private enum DownloadQueueError: LocalizedError {
        case queueNotAvailable
        case itemProcessingTimedOut
        case itemFailed(String)
        case invalidQueueResponse
        case mediaFetchFailed(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .queueNotAvailable:
                return "Download queue not available on this server"
            case .itemProcessingTimedOut:
                return "Download queue item timed out while processing"
            case .itemFailed(let reason):
                return "Download queue item failed: \(reason)"
            case .invalidQueueResponse:
                return "Invalid download queue response"
            case .mediaFetchFailed(let statusCode):
                return "Download queue media fetch failed with status \(statusCode)"
            }
        }
    }

    private struct DownloadQueueEnvelope: Decodable {
        let MediaContainer: DownloadQueueMediaContainer
    }

    private struct DownloadQueueMediaContainer: Decodable {
        let DownloadQueue: [DownloadQueueRecord]?
        let AddedQueueItems: [DownloadQueueAddedItem]?
        let DownloadQueueItem: [DownloadQueueItemRecord]?
    }

    private struct DownloadQueueRecord: Decodable {
        let id: Int
    }

    private struct DownloadQueueAddedItem: Decodable {
        let id: Int
    }

    private struct DownloadQueueItemRecord: Decodable {
        let id: Int
        let status: String
        let error: String?
    }

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

    // Centralized endpoint registry — when set, failover results are reported back
    private let connectionRegistry: ServerConnectionRegistry?
    private let serverKey: String?

    private static let plexTVBaseURL = "https://plex.tv"

    /// Initialize with a direct server connection
    /// - Parameters:
    ///   - connection: Server connection configuration
    ///   - librarySelection: Optional library selection
    ///   - keychain: Keychain for token persistence
    ///   - failoverManager: Manages connection failover probing
    ///   - connectionRegistry: Centralized endpoint registry — failover results are written back here
    ///   - serverKey: Registry key for this server (required when registry is provided)
    ///   - productName: Client product name for Plex headers
    ///   - productVersion: Client product version for Plex headers
    public init(
        connection: PlexServerConnection,
        librarySelection: PlexLibrarySelection? = nil,
        keychain: KeychainServiceProtocol = KeychainService.shared,
        failoverManager: ConnectionFailoverManager = ConnectionFailoverManager(),
        connectionRegistry: ServerConnectionRegistry? = nil,
        serverKey: String? = nil,
        productName: String = "Ensemble",
        productVersion: String = "1.0"
    ) {
        self.keychain = keychain
        self.serverConnection = connection
        self.selectedLibrary = librarySelection
        self.currentServerURL = connection.url
        self.failoverManager = failoverManager
        self.connectionRegistry = connectionRegistry
        self.serverKey = serverKey
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

        // Seed the registry with the initial endpoint so consumers (e.g. WebSocket
        // coordinator) have a valid URL before the first health check completes.
        if let registry = connectionRegistry, let key = serverKey {
            let endpoint = connection.endpoints.first
                ?? PlexEndpointDescriptor(url: connection.url, local: false, relay: false)
            Task { await registry.updateEndpoint(for: key, endpoint: endpoint, source: .connectionRefresh) }
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

    /// Get multiple tracks in a single batch request
    /// This is more efficient than making multiple getTrack calls when you need to fetch several tracks
    /// - Parameter ratingKeys: Array of track rating keys to fetch
    /// - Returns: Array of tracks matching the provided keys (may be fewer if some keys don't exist)
    public func getTracks(ratingKeys: [String]) async throws -> [PlexTrack] {
        guard !ratingKeys.isEmpty else { return [] }
        
        // Join rating keys with commas for batch request
        let ids = ratingKeys.joined(separator: ",")
        
        #if DEBUG
        EnsembleLogger.debug("📦 Fetching \(ratingKeys.count) tracks in batch")
        #endif
        
        let data = try await serverRequest(
            path: "/library/metadata/\(ids)"
        )
        
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        
        #if DEBUG
        EnsembleLogger.debug("✅ Batch fetch returned \(container.mediaContainer.items.count) tracks")
        #endif
        
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
    public func getHubs(sectionKey: String, count: String = "12") async throws -> [PlexHub] {
        // Adding count and includeLibrary ensures we get items back in the Metadata array.
        // Different count values cause PMS to select different dynamic hub content
        // (e.g. "More by...", "More in..." sections rotate based on count).
        let data = try await serverRequest(
            path: "/hubs/sections/\(sectionKey)",
            query: [
                "count": count,
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

    /// Generate transcode streaming URL using Plex's universal transcode endpoint.
    /// Accepts a rating key (e.g. "8257") or a full library path (e.g. "/library/metadata/8257").
    public func getTranscodeStreamURL(trackKey: String, quality: StreamingQuality) async throws -> URL {
        try await getTranscodeStreamURL(
            trackKey: trackKey,
            quality: quality,
            useAbsolutePathParameter: false,
            useAudioEndpoint: false,
            useStartWithoutExtension: false
        )
    }

    /// Download transcoded media using Plex's download queue flow.
    /// This "primes" server-side transcode before media retrieval and is closer
    /// to the flow used by first-party offline clients.
    public func downloadTranscodedMediaViaQueue(
        trackRatingKey: String,
        quality: StreamingQuality
    ) async throws -> (data: Data, suggestedFilename: String?, mimeType: String?) {
        guard quality != .original else {
            throw DownloadQueueError.queueNotAvailable
        }

        let queueId = try await getOrCreateDownloadQueueID()
        let metadataKey = "/library/metadata/\(trackRatingKey)"
        let itemId = try await addDownloadQueueItem(
            queueId: queueId,
            metadataKey: metadataKey,
            quality: quality
        )

        #if DEBUG
        EnsembleLogger.debug(
            "⬇️ DownloadQueue enqueued: queue=\(queueId) item=\(itemId) track=\(trackRatingKey) quality=\(quality.rawValue)"
        )
        #endif

        // Poll with exponential backoff until the item is ready.
        // Starts at 1s, doubles each iteration, capped at 15s.
        let timeoutDeadline = Date().addingTimeInterval(120)
        var pollInterval: UInt64 = 1_000_000_000 // 1s initial
        let maxPollInterval: UInt64 = 15_000_000_000 // 15s cap
        while Date() < timeoutDeadline {
            let item = try await getDownloadQueueItem(queueId: queueId, itemId: itemId)
            switch item.status {
            case "available":
                let media = try await fetchDownloadQueueMedia(queueId: queueId, itemId: itemId)
                return media
            case "error":
                throw DownloadQueueError.itemFailed(item.error ?? "Unknown queue error")
            case "expired":
                try await restartDownloadQueueItem(queueId: queueId, itemId: itemId)
                try? await Task.sleep(nanoseconds: pollInterval)
            case "deciding", "waiting", "processing":
                try? await Task.sleep(nanoseconds: pollInterval)
            default:
                try? await Task.sleep(nanoseconds: pollInterval)
            }
            pollInterval = min(pollInterval * 2, maxPollInterval)
        }

        throw DownloadQueueError.itemProcessingTimedOut
    }

    /// Generate a transcode URL with endpoint and path-shape fallbacks.
    public func getTranscodeStreamURL(
        trackKey: String,
        quality: StreamingQuality,
        useAbsolutePathParameter: Bool,
        useAudioEndpoint: Bool,
        useStartWithoutExtension: Bool
    ) async throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getTranscodeStreamURL: \(trackKey) [quality: \(quality.rawValue)]")
        #endif
        
        guard var components = URLComponents(string: currentServerURL) else {
            throw PlexAPIError.invalidURL
        }
        
        components.path = transcodeStartPath(
            useAudioEndpoint: useAudioEndpoint,
            useStartWithoutExtension: useStartWithoutExtension
        )
        
        // Map quality to bitrate
        let bitrate: String
        switch quality {
        case .original:
            bitrate = "320" // Use high quality when transcoding "original"
        case .high:
            bitrate = "320"
        case .medium:
            bitrate = "192"
        case .low:
            bitrate = "128"
        }
        
        let normalizedPath: String
        if trackKey.hasPrefix("/library/") {
            normalizedPath = trackKey
        } else if trackKey.allSatisfy({ $0.isNumber }) {
            normalizedPath = "/library/metadata/\(trackKey)"
        } else if trackKey.hasPrefix("/") {
            normalizedPath = trackKey
        } else {
            normalizedPath = "/\(trackKey)"
        }
        let transcodePath: String
        if useAbsolutePathParameter {
            guard let baseURL = URL(string: currentServerURL),
                  let absolutePathURL = URL(string: normalizedPath, relativeTo: baseURL)?.absoluteURL else {
                throw PlexAPIError.invalidURL
            }
            transcodePath = absolutePathURL.absoluteString
        } else {
            transcodePath = normalizedPath
        }

        let sessionId = UUID().uuidString
        var queryItems = [
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "path", value: transcodePath),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            // `musicBitrate` is the canonical query parameter for audio-only
            // transcoding. Keep `audioBitrate` for older server compatibility.
            URLQueryItem(name: "musicBitrate", value: bitrate),
            URLQueryItem(name: "audioBitrate", value: bitrate),
            // Target codec tells PMS what to transcode to
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]
        queryItems.append(contentsOf: transcodeClientQueryItems(sessionId: sessionId))
        // Force transcoding — disable direct play/stream so PMS doesn't skip transcode
        queryItems.removeAll { $0.name == "directPlay" }
        queryItems.removeAll { $0.name == "directStream" }
        queryItems.removeAll { $0.name == "directStreamAudio" }
        queryItems.append(URLQueryItem(name: "directPlay", value: "0"))
        queryItems.append(URLQueryItem(name: "directStream", value: "0"))
        queryItems.append(URLQueryItem(name: "directStreamAudio", value: "0"))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }
        
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getTranscodeStreamURL normalized path: \(normalizedPath)")
        EnsembleLogger.debug("✅ Created transcode stream URL: \(url)")
        #endif

        return url
    }

    /// Generate a transcode URL with optional absolute-path parameter fallback.
    /// Some PMS builds reject relative `/library/...` path values for transcode requests.
    public func getTranscodeStreamURL(
        trackKey: String,
        quality: StreamingQuality,
        useAbsolutePathParameter: Bool
    ) async throws -> URL {
        try await getTranscodeStreamURL(
            trackKey: trackKey,
            quality: quality,
            useAbsolutePathParameter: useAbsolutePathParameter,
            useAudioEndpoint: false,
            useStartWithoutExtension: false
        )
    }
    
    /// Generate streaming URL for a track using universal transcode endpoint
    /// This endpoint works for both Plex Pass and non-Plex Pass users by intelligently
    /// choosing between direct play, direct stream, or transcode based on server capabilities
    /// Get a universal stream URL for a track.
    /// Delegates to the ratingKey overload which handles the decision endpoint call.
    public func getUniversalStreamURL(
        for track: PlexTrack,
        quality: StreamingQuality = .original,
        sessionId: String? = nil
    ) async throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getUniversalStreamURL: \(track.title) [quality: \(quality.rawValue)]")
        #endif
        return try await getUniversalStreamURL(
            ratingKey: track.ratingKey,
            quality: quality,
            sessionId: sessionId
        )
    }

    /// Get a universal stream URL for a track, warming up the transcode session first.
    /// The decision endpoint MUST be called before start.mp3 or PMS returns 400.
    /// Get a universal stream URL for a track, warming up the transcode session first.
    /// The decision endpoint MUST be called before start.mp3 or PMS returns 400.
    public func getUniversalStreamURL(
        ratingKey: String,
        quality: StreamingQuality = .original,
        sessionId: String? = nil
    ) async throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.getUniversalStreamURL(ratingKey): \(ratingKey) [quality: \(quality.rawValue)]")
        #endif

        let resolvedSessionId = sessionId ?? UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: resolvedSessionId
        )

        // Step 1: Call the decision endpoint to warm up the transcode session.
        // Without this, PMS returns 400 on the start endpoint.
        try await callTranscodeDecision(queryItems: queryItems)

        // Step 2: Build the start.mp3 URL with manual encoding (see buildTranscodeURL)
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        #if DEBUG
        EnsembleLogger.debug("✅ Created universal stream URL")
        #endif

        return url
    }

    /// Download a universal transcode stream to a temporary file and return the file URL.
    ///
    /// AVPlayer's CoreMedia HTTP stack (CFHTTP) fails to parse chunked responses from PMS's
    /// transcode endpoint (Transfer-Encoding: chunked, no Content-Length, Connection: close).
    /// This manifests as CFHTTP error -16845 / NSURLErrorResourceUnavailable. Downloading via
    /// URLSession (which handles chunked encoding correctly) and playing from a local file
    /// bypasses the issue entirely.
    ///
    /// The decision endpoint MUST be called before start.mp3. Without it, PMS returns HTTP 400.
    /// Each download uses a unique session ID, so concurrent prefetch downloads do not conflict.
    public func downloadUniversalStreamToFile(
        ratingKey: String,
        quality: StreamingQuality = .original,
        sessionId: String? = nil,
        metadataDurationSeconds: Double? = nil
    ) async throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexAPIClient.downloadUniversalStreamToFile(ratingKey): \(ratingKey) [quality: \(quality.rawValue)]")
        #endif

        let resolvedSessionId = sessionId ?? UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: resolvedSessionId
        )

        // Warm up the transcode session — PMS requires this before start.mp3.
        // Decision tolerates URLComponents encoding, so it can use queryItems directly.
        try await callTranscodeDecision(queryItems: queryItems)

        // Build the start.mp3 URL with manual query encoding.
        // URLComponents encodes `=` as `%3D` inside query values, but PMS's start.mp3
        // endpoint requires literal `=` inside X-Plex-Client-Profile-Extra
        // (e.g., `type=musicProfile`). The decision endpoint tolerates %3D but start.mp3
        // returns 400. We manually encode only `&` (as %26) and leave `=` literal.
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        #if DEBUG
        EnsembleLogger.debug("🔗 Downloading universal stream for ratingKey \(ratingKey) [session: \(resolvedSessionId.prefix(8))]")
        #endif

        // Download the stream to a temp file via URLSession.download.
        // URLSession handles chunked encoding and Connection: close correctly.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        addPlexHeaders(to: &request, token: serverConnection.token)

        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            #if DEBUG
            EnsembleLogger.debug("⚠️ Universal stream download returned \(statusCode)")
            #endif
            throw PlexAPIError.httpError(statusCode: statusCode)
        }

        // Move to a stable temp location (URLSession temp files get cleaned up)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Determine file extension from content type so AVPlayer can identify the format.
        // For non-original quality, PMS always produces MP3 regardless of source codec.
        let fileExtension: String
        if quality != .original {
            fileExtension = "mp3"
        } else {
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            switch contentType.lowercased() {
            case let ct where ct.contains("flac"):
                fileExtension = "flac"
            case let ct where ct.contains("mp4"), let ct where ct.contains("m4a"):
                fileExtension = "m4a"
            case let ct where ct.contains("mpeg"), let ct where ct.contains("mp3"):
                fileExtension = "mp3"
            case let ct where ct.contains("wav"):
                fileExtension = "wav"
            case let ct where ct.contains("aac"):
                fileExtension = "aac"
            default:
                // Unknown content type — use generic extension, AVPlayer will try to sniff
                fileExtension = "audio"
                #if DEBUG
                EnsembleLogger.debug("⚠️ Unknown Content-Type for original quality stream: '\(contentType)'")
                #endif
            }
            #if DEBUG
            EnsembleLogger.debug("📦 Original quality Content-Type: '\(contentType)' → .\(fileExtension)")
            #endif
        }
        let destURL = cacheDir.appendingPathComponent("\(ratingKey)_\(resolvedSessionId).\(fileExtension)")

        // Remove stale file if it exists (e.g., from a crashed session)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        // PMS's universal transcode produces VBR MP3 files without XING headers.
        // Inject a XING header with accurate frame count, byte count, and LAME
        // gapless metadata (encoder delay/padding). This fixes AVPlayer duration
        // overestimation and provides gapless metadata at track boundaries.
        //
        // Note: CAF conversion (uncompressed PCM) was previously used here for
        // zero-gap gapless but created ~60MB files per track and took ~13 seconds,
        // causing memory leaks and blocking playback startup on low-RAM devices.
        // XING header injection is ~1ms and keeps the ~6MB MP3 file as-is.
        if quality != .original {
            try? MP3VBRHeaderUtility.injectXingHeaderIfNeeded(
                at: destURL,
                metadataDurationSeconds: metadataDurationSeconds
            )
        }

        #if DEBUG
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        EnsembleLogger.debug("✅ Downloaded universal stream to file: \(destURL.lastPathComponent) (\(fileSize) bytes)")
        #endif

        return destURL
    }

    /// Resolve the best streaming approach for a track.
    ///
    /// Tries direct stream first (instant playback) and falls back to full transcode
    /// download when PMS says transcoding is needed.
    ///
    /// - `original` quality with a stream key: direct stream URL, no decision call needed.
    /// - Non-original quality: calls the decision endpoint. If PMS says `directplay` or `copy`,
    ///   uses the direct stream URL. If `transcode` or `unknown`, downloads the full file.
    /// - No stream key available: always downloads via the transcode pipeline.
    public func resolveStreamURL(
        ratingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution {
        // Original quality with a known stream key — skip the decision call entirely
        // and stream the file directly. PMS serves these with Accept-Ranges: bytes
        // and Content-Length, which AVPlayer handles natively.
        if quality == .original, let streamKey = trackStreamKey, !streamKey.isEmpty {
            let url = try getStreamURL(trackKey: streamKey)
            #if DEBUG
            EnsembleLogger.debug("🎵 resolveStreamURL: original quality → direct stream")
            #endif
            return .directStream(url)
        }

        // Non-original quality — ask PMS what it would do
        if let streamKey = trackStreamKey, !streamKey.isEmpty {
            let sessionId = UUID().uuidString
            let queryItems = buildUniversalStreamQueryItems(
                ratingKey: ratingKey,
                quality: quality,
                sessionId: sessionId
            )

            let decision = try await callTranscodeDecision(queryItems: queryItems)

            switch decision.decision {
            case .directplay, .copy:
                // PMS says no transcoding needed — use direct file stream.
                // Prefer the part key from the decision response if available,
                // otherwise fall back to the track's stored stream key.
                let partKey = decision.directStreamPartKey ?? streamKey
                let url = try getStreamURL(trackKey: partKey)
                #if DEBUG
                EnsembleLogger.debug("🎵 resolveStreamURL: decision=\(decision.decision.rawValue) → direct stream")
                #endif
                return .directStream(url)

            case .transcode, .unknown:
                // Transcoding required — download the full file with XING header injection.
                // Reuse the same session ID so PMS recognizes the warmed-up session.
                #if DEBUG
                EnsembleLogger.debug("🎵 resolveStreamURL: decision=\(decision.decision.rawValue) → downloading transcode")
                #endif
                let fileURL = try await downloadUniversalStreamToFileWithSession(
                    ratingKey: ratingKey,
                    quality: quality,
                    sessionId: sessionId,
                    queryItems: queryItems,
                    metadataDurationSeconds: metadataDurationSeconds
                )
                return .downloadedFile(fileURL)
            }
        }

        // No stream key — can only use the transcode pipeline
        #if DEBUG
        EnsembleLogger.debug("🎵 resolveStreamURL: no stream key → downloading transcode")
        #endif
        let fileURL = try await downloadUniversalStreamToFile(
            ratingKey: ratingKey,
            quality: quality,
            metadataDurationSeconds: metadataDurationSeconds
        )
        return .downloadedFile(fileURL)
    }

    /// Download universal stream with a pre-warmed session.
    /// Used by `resolveStreamURL` when the decision endpoint has already been called —
    /// skips the redundant decision call and reuses the same session ID.
    private func downloadUniversalStreamToFileWithSession(
        ratingKey: String,
        quality: StreamingQuality,
        sessionId: String,
        queryItems: [URLQueryItem],
        metadataDurationSeconds: Double?
    ) async throws -> URL {
        // Build the start.mp3 URL (decision was already called by the caller)
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        #if DEBUG
        EnsembleLogger.debug("🔗 Downloading universal stream for ratingKey \(ratingKey) [session: \(sessionId.prefix(8))]")
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        addPlexHeaders(to: &request, token: serverConnection.token)

        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            #if DEBUG
            EnsembleLogger.debug("⚠️ Universal stream download returned \(statusCode)")
            #endif
            throw PlexAPIError.httpError(statusCode: statusCode)
        }

        // Move to stable temp location and determine file extension
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let fileExtension: String
        if quality != .original {
            fileExtension = "mp3"
        } else {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            switch contentType.lowercased() {
            case let ct where ct.contains("flac"):
                fileExtension = "flac"
            case let ct where ct.contains("mp4"), let ct where ct.contains("m4a"):
                fileExtension = "m4a"
            case let ct where ct.contains("mpeg"), let ct where ct.contains("mp3"):
                fileExtension = "mp3"
            case let ct where ct.contains("wav"):
                fileExtension = "wav"
            case let ct where ct.contains("aac"):
                fileExtension = "aac"
            default:
                fileExtension = "audio"
                #if DEBUG
                EnsembleLogger.debug("⚠️ Unknown Content-Type for stream: '\(contentType)'")
                #endif
            }
        }

        let destURL = cacheDir.appendingPathComponent("\(ratingKey)_\(sessionId).\(fileExtension)")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        // Inject XING VBR header for transcoded MP3s (fixes duration and enables gapless)
        if quality != .original {
            try? MP3VBRHeaderUtility.injectXingHeaderIfNeeded(
                at: destURL,
                metadataDurationSeconds: metadataDurationSeconds
            )
        }

        #if DEBUG
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        EnsembleLogger.debug("✅ Downloaded universal stream to file: \(destURL.lastPathComponent) (\(fileSize) bytes)")
        #endif

        return destURL
    }

    /// Build a universal download URL for offline use, skipping the decision endpoint.
    /// The decision call is only needed for AVPlayer streaming (session warmup); URLSession
    /// downloads work without it, saving an unnecessary HTTP roundtrip per download.
    public func getUniversalDownloadURL(
        ratingKey: String,
        quality: StreamingQuality = .original
    ) throws -> URL {
        let sessionId = UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: sessionId
        )

        // Use manual encoding — see buildTranscodeURL for rationale
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        #if DEBUG
        EnsembleLogger.debug("✅ Created universal download URL (no decision): \(url)")
        #endif

        return url
    }

    /// Build query items for universal transcode endpoints (shared by decision and start).
    private func buildUniversalStreamQueryItems(
        ratingKey: String,
        quality: StreamingQuality,
        sessionId: String
    ) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]
        queryItems.append(contentsOf: transcodeClientQueryItems(sessionId: sessionId))

        // Quality-specific bitrate hints.
        switch quality {
        case .original:
            break
        case .high:
            queryItems.append(URLQueryItem(name: "musicBitrate", value: "320"))
            queryItems.append(URLQueryItem(name: "audioBitrate", value: "320"))
        case .medium:
            queryItems.append(URLQueryItem(name: "musicBitrate", value: "192"))
            queryItems.append(URLQueryItem(name: "audioBitrate", value: "192"))
        case .low:
            queryItems.append(URLQueryItem(name: "musicBitrate", value: "128"))
            queryItems.append(URLQueryItem(name: "audioBitrate", value: "128"))
        }

        return queryItems
    }

    /// Call the transcode decision endpoint to warm up the session and parse PMS's decision.
    /// Returns the decision (directplay/copy/transcode) and the part key for direct streaming.
    /// This must be called before start.mp3 or PMS returns 400.
    @discardableResult
    private func callTranscodeDecision(queryItems: [URLQueryItem]) async throws -> TranscodeDecisionResult {
        // Use the same manual encoding as start.mp3 for consistency
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/decision",
            queryItems: queryItems
        )

        #if DEBUG
        EnsembleLogger.debug("🔄 Calling transcode decision endpoint")
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addPlexHeaders(to: &request, token: serverConnection.token)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        // Only accept 200 — if decision returns 400, the session wasn't warmed up
        // and the subsequent start.mp3 download will also fail with 400
        guard httpResponse.statusCode == 200 else {
            #if DEBUG
            EnsembleLogger.debug("⚠️ Transcode decision returned \(httpResponse.statusCode)")
            #endif
            throw PlexAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse the decision from the JSON response.
        // Structure: { MediaContainer: { Metadata: [{ Media: [{ Part: [{ decision, key }] }] }] } }
        let result = parseTranscodeDecision(from: data)

        #if DEBUG
        EnsembleLogger.debug("✅ Transcode decision completed: \(result.decision.rawValue), partKey: \(result.directStreamPartKey ?? "nil")")
        #endif

        return result
    }

    /// Parse the transcode decision JSON into a structured result.
    /// Returns `.unknown` with nil part key on any parse failure (safe fallback).
    private func parseTranscodeDecision(from data: Data) -> TranscodeDecisionResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any],
              let metadata = (container["Metadata"] as? [[String: Any]])?.first,
              let media = (metadata["Media"] as? [[String: Any]])?.first,
              let part = (media["Part"] as? [[String: Any]])?.first else {
            return TranscodeDecisionResult(decision: .unknown, directStreamPartKey: nil)
        }

        let decisionString = (part["decision"] as? String) ?? ""
        let decision = TranscodeDecisionResult.Decision(rawValue: decisionString) ?? .unknown
        let partKey = part["key"] as? String

        return TranscodeDecisionResult(decision: decision, directStreamPartKey: partKey)
    }

    /// Build a transcode URL with manual query encoding.
    ///
    /// PMS's start.mp3 endpoint requires literal `=` inside X-Plex-Client-Profile-Extra
    /// values (e.g., `type=musicProfile&context=streaming`). Swift's `URLComponents` encodes
    /// `=` as `%3D` in query values, which the decision endpoint tolerates but start.mp3
    /// rejects with 400. This method uses percent-encoding that keeps `=`, `+`, `(`, `)`,
    /// and `/` literal while encoding `&`, spaces, and non-ASCII characters. The non-ASCII
    /// encoding is critical for iOS 15 whose URL parser rejects non-ASCII in URL strings
    /// (e.g., curly apostrophes in device names like "Felicity\u{2019}s iPhone").
    private func buildTranscodeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        // Character set: urlQueryAllowed minus `&` (which separates query params).
        // This keeps = + ( ) / : @ literal while encoding & spaces and non-ASCII.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&")

        let query = queryItems.map { item -> String in
            let value = item.value ?? ""
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(item.name)=\(encoded)"
        }.joined(separator: "&")

        guard let url = URL(string: "\(currentServerURL)\(path)?\(query)") else {
            throw PlexAPIError.invalidURL
        }
        return url
    }

    private func transcodeClientQueryItems(sessionId: String) -> [URLQueryItem] {
        [
            // Session identity and broad client metadata improve compatibility on
            // servers that enforce transcode profile matching.
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionId),
            URLQueryItem(name: "transcodeSessionId", value: sessionId),
            // Some server versions key transcode sessions off `session`.
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "X-Plex-Product", value: productName),
            URLQueryItem(name: "X-Plex-Platform", value: platformName),
            URLQueryItem(name: "X-Plex-Device", value: deviceName),
            URLQueryItem(name: "X-Plex-Device-Name", value: deviceName),
            // DO NOT include X-Plex-Client-Profile-Name — "generic" causes PMS to
            // return 400 on start.mp3 (decision tolerates it, but the stream rejects it).
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: transcodeClientProfileExtra()),
            // directPlay=0 prevents PMS from redirecting to the raw file URL.
            // Non-Plex Pass servers limit raw file downloads (~655KB), which cuts
            // off playback mid-stream. directStream=1 tells PMS to stream the
            // original codec through its pipeline without transcoding.
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "hasMDE", value: "1")
        ]
    }

    private func transcodeClientProfileExtra() -> String {
        // Transcode targets: codecs PMS should transcode TO when original isn't compatible.
        // Only MP3 here — AAC was removed because PMS silently produces 0-byte output
        // when transcoding high-sample-rate FLAC (e.g. 96kHz/24-bit) to AAC.
        //
        // Direct-play codecs: codecs AVPlayer can play natively, so PMS can direct-stream them.
        // AAC stays here (client can *play* AAC, just shouldn't ask PMS to *transcode to* it).
        // Both are needed -- without direct-play declarations, PMS may refuse to stream
        // formats like FLAC even when the client supports them.
        [
            "add-transcode-target-codec(type=musicProfile&context=streaming&protocol=http&audioCodec=mp3)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=aac)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=mp3)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=flac)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=alac)",
        ].joined(separator: "+")
    }

    private func transcodeStartPath(
        useAudioEndpoint: Bool,
        useStartWithoutExtension: Bool
    ) -> String {
        let transcodeType = useAudioEndpoint ? "audio" : "music"
        let startComponent = useStartWithoutExtension ? "start" : "start.mp3"
        return "/\(transcodeType)/:/transcode/universal/\(startComponent)"
    }

    private func getOrCreateDownloadQueueID() async throws -> Int {
        let data = try await serverRequestPOST(path: "/downloadQueue")
        let decoded = try JSONDecoder().decode(DownloadQueueEnvelope.self, from: data)
        guard let queueId = decoded.MediaContainer.DownloadQueue?.first?.id else {
            throw DownloadQueueError.invalidQueueResponse
        }
        return queueId
    }

    private func addDownloadQueueItem(
        queueId: Int,
        metadataKey: String,
        quality: StreamingQuality
    ) async throws -> Int {
        let bitrate = downloadQueueBitrate(for: quality)
        var query: [String: String] = [
            "keys": metadataKey,
            "path": metadataKey,
            "protocol": "http",
            "mediaIndex": "0",
            "partIndex": "0",
            "directPlay": "0",
            "directStream": "0",
            "directStreamAudio": "0",
            "hasMDE": "1"
        ]
        if let bitrate {
            query["musicBitrate"] = bitrate
            query["audioBitrate"] = bitrate
        }

        let data = try await serverRequestPOST(path: "/downloadQueue/\(queueId)/add", query: query)
        let decoded = try JSONDecoder().decode(DownloadQueueEnvelope.self, from: data)
        guard let itemId = decoded.MediaContainer.AddedQueueItems?.first?.id else {
            throw DownloadQueueError.invalidQueueResponse
        }
        return itemId
    }

    private func getDownloadQueueItem(queueId: Int, itemId: Int) async throws -> DownloadQueueItemRecord {
        let data = try await serverRequest(path: "/downloadQueue/\(queueId)/items/\(itemId)")
        let decoded = try JSONDecoder().decode(DownloadQueueEnvelope.self, from: data)
        guard let item = decoded.MediaContainer.DownloadQueueItem?.first else {
            throw DownloadQueueError.invalidQueueResponse
        }
        return item
    }

    private func restartDownloadQueueItem(queueId: Int, itemId: Int) async throws {
        _ = try await serverRequestPOST(path: "/downloadQueue/\(queueId)/items/\(itemId)/restart")
    }

    private func fetchDownloadQueueMedia(
        queueId: Int,
        itemId: Int
    ) async throws -> (data: Data, suggestedFilename: String?, mimeType: String?) {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let request = try makeServerRequest(
                url: currentServerURL,
                method: "GET",
                path: "/downloadQueue/\(queueId)/item/\(itemId)/media"
            )
            let (data, response) = try await performRequestAllowingNon2xx(request)

            if response.statusCode == 200 {
                let suggestedFilename = response.value(forHTTPHeaderField: "Content-Disposition")
                    .flatMap { contentDisposition -> String? in
                        let marker = "filename="
                        guard let range = contentDisposition.range(of: marker) else { return nil }
                        let filename = contentDisposition[range.upperBound...]
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        return filename.isEmpty ? nil : String(filename)
                    }
                let mimeType = response.value(forHTTPHeaderField: "Content-Type")
                return (data, suggestedFilename, mimeType)
            }

            if response.statusCode == 503 {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Int.init) ?? 1
                try? await Task.sleep(nanoseconds: UInt64(max(retryAfter, 1)) * 1_000_000_000)
                continue
            }

            throw DownloadQueueError.mediaFetchFailed(statusCode: response.statusCode)
        }

        throw DownloadQueueError.itemProcessingTimedOut
    }

    private func downloadQueueBitrate(for quality: StreamingQuality) -> String? {
        switch quality {
        case .high:
            return "320"
        case .medium:
            return "192"
        case .low:
            return "128"
        case .original:
            return nil
        }
    }
    
    /// Generate streaming URL for a track (legacy direct file access)
    /// Note: This may fail for non-Plex Pass users. Use getUniversalStreamURL instead.
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

    // MARK: - Lyrics

    /// Fetches raw lyrics content from a stream key path (e.g. `/library/streams/12345`)
    /// Returns the UTF-8 text content, or nil on 404/error
    /// Fetch lyrics content for a given stream key.
    /// Uses format=xml (matching Plexamp) and retries once on 404 since PMS
    /// caches LyricFind lyrics briefly and may need a moment to re-fetch.
    public func getLyricsContent(streamKey: String) async throws -> String? {
        // Plexamp fetches lyrics with format=xml; Accept: application/json from
        // addPlexHeaders causes PMS to return JSON instead. We handle both formats.
        let query = ["format": "xml", "includeInlineAttribution": "1"]

        // Attempt fetch with one retry — PMS may return 404 if its LyricFind cache
        // expired and needs a moment to re-fetch from the provider.
        for attempt in 1...2 {
            do {
                let data = try await serverRequest(path: streamKey, query: query)

                // Try JSON extraction (when Accept: application/json triggers JSON response)
                if let text = Self.extractLyricsFromJSON(data) {
                    return text
                }

                // Try XML extraction (when format=xml is respected)
                if let text = Self.extractLyricsFromXML(data) {
                    return text
                }

                // Fall back to treating the response as raw text (plain LRC/TXT)
                return String(data: data, encoding: .utf8)
            } catch {
                let isHTTP404 = "\(error)".contains("404")
                if isHTTP404 && attempt == 1 {
                    // Brief delay before retry — gives PMS time to re-fetch from LyricFind
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                    continue
                }
                #if DEBUG
                EnsembleLogger.debug("Lyrics content not available at \(streamKey) (attempt \(attempt)): \(error.localizedDescription)")
                #endif
                return nil
            }
        }
        return nil
    }

    // MARK: - Lyrics Parsing Helpers

    /// Extract lyrics text from a Plex JSON MediaContainer response.
    /// PMS returns structured lyrics as MediaContainer.Lyrics[].Line[].Span[].text
    private static func extractLyricsFromJSON(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any] else {
            return nil
        }

        // Structured lyrics: MediaContainer.Lyrics[].Line[].Span[].text with minMs timestamps
        if let lyricsArray = container["Lyrics"] as? [[String: Any]],
           let firstLyrics = lyricsArray.first,
           let lines = firstLyrics["Line"] as? [[String: Any]] {
            return buildLRCFromStructuredLines(lines: lines)
        }

        // Stream value fallback: MediaContainer.Metadata[].Stream[].value
        if let metadata = container["Metadata"] as? [[String: Any]] {
            for meta in metadata {
                if let streams = meta["Stream"] as? [[String: Any]] {
                    for stream in streams {
                        if let value = stream["value"] as? String, !value.isEmpty {
                            return value
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Extract lyrics from Plex XML response (format=xml).
    /// XML structure: <MediaContainer><Lyrics><Line minMs="..."><Span text="..."/></Line>...</Lyrics></MediaContainer>
    private static func extractLyricsFromXML(_ data: Data) -> String? {
        let parser = LyricsXMLParser(data: data)
        let lines = parser.parse()
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Build LRC text from Plex's structured lyrics format.
    /// Each Line has a timestamp in milliseconds (startOffset or minMs) and Span text segments.
    private static func buildLRCFromStructuredLines(lines: [[String: Any]]) -> String {
        var lrcLines: [String] = []

        for line in lines {
            // Get the text from Span array
            var lineText = ""
            if let spans = line["Span"] as? [[String: Any]] {
                lineText = spans.compactMap { $0["text"] as? String }.joined()
            }
            guard !lineText.isEmpty else { continue }

            // Build timestamp if available — PMS uses "startOffset" (JSON) or "minMs" (XML)
            let offsetMs = Self.extractInt(from: line, key: "startOffset")
                ?? Self.extractInt(from: line, key: "minMs")
            if let ms = offsetMs {
                let totalSeconds = Double(ms) / 1000.0
                let minutes = Int(totalSeconds) / 60
                let seconds = Int(totalSeconds) % 60
                let centiseconds = Int((totalSeconds - Double(Int(totalSeconds))) * 100)
                lrcLines.append(String(format: "[%02d:%02d.%02d]%@", minutes, seconds, centiseconds, lineText))
            } else {
                lrcLines.append(lineText)
            }
        }

        return lrcLines.joined(separator: "\n")
    }

    /// Helper to extract an Int from a dictionary value that may be Int or String
    private static func extractInt(from dict: [String: Any], key: String) -> Int? {
        if let intVal = dict[key] as? Int { return intVal }
        if let strVal = dict[key] as? String { return Int(strVal) }
        return nil
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

        // Report winning endpoint back to the centralized registry
        if let registry = connectionRegistry, let key = serverKey {
            await registry.updateEndpoint(for: key, endpoint: endpoint, source: .requestFailover)
        }

        #if DEBUG
        EnsembleLogger.debug("✅ Found working connection: \(endpoint.url)")
        #endif
        return selection
    }

    /// Get the current active server URL
    public func getCurrentServerURL() -> String {
        currentServerURL
    }

    /// Update the current server URL (e.g., from external health checks or registry sync).
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
        PlexErrorClassification.classify(error).shouldFailover
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

    private func performRequestAllowingNon2xx(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if Task.isCancelled {
            throw CancellationError()
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlexAPIError.invalidResponse
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

// MARK: - Lyrics XML Parser

/// Parses Plex's XML lyrics response format (used when format=xml is requested).
/// XML structure: <MediaContainer><Lyrics><Line minMs="..."><Span text="..."/></Line>...</Lyrics></MediaContainer>
private class LyricsXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var lrcLines: [String] = []
    private var currentMinMs: Int?
    private var currentSpans: [String] = []
    private var inLine = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return lrcLines
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "Line" {
            inLine = true
            currentSpans = []
            // PMS uses "startOffset" (not "minMs") for timestamps in milliseconds
            let msStr = attributes["startOffset"] ?? attributes["minMs"]
            if let msStr, let ms = Int(msStr) {
                currentMinMs = ms
            } else {
                currentMinMs = nil
            }
        } else if elementName == "Span" && inLine {
            if let text = attributes["text"] {
                currentSpans.append(text)
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "Line" && inLine {
            inLine = false
            let lineText = currentSpans.joined()
            guard !lineText.isEmpty else { return }

            if let minMs = currentMinMs {
                let totalSeconds = Double(minMs) / 1000.0
                let minutes = Int(totalSeconds) / 60
                let seconds = Int(totalSeconds) % 60
                let centiseconds = Int((totalSeconds - Double(Int(totalSeconds))) * 100)
                lrcLines.append(String(format: "[%02d:%02d.%02d]%@", minutes, seconds, centiseconds, lineText))
            } else {
                lrcLines.append(lineText)
            }
        }
    }
}
