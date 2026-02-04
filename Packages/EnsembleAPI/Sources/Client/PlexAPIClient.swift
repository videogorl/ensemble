import Foundation

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
    public let token: String
    public let identifier: String
    public let name: String

    public init(
        url: String,
        alternativeURLs: [String] = [],
        token: String,
        identifier: String,
        name: String
    ) {
        self.url = url
        self.alternativeURLs = alternativeURLs
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
        failoverManager: ConnectionFailoverManager = ConnectionFailoverManager()
    ) {
        self.keychain = keychain
        self.serverConnection = connection
        self.selectedLibrary = librarySelection
        self.currentServerURL = connection.url
        self.failoverManager = failoverManager

        if let existingId = try? keychain.get(KeychainKey.plexClientIdentifier) {
            self.clientIdentifier = existingId
        } else {
            let newId = UUID().uuidString
            try? keychain.save(newId, forKey: KeychainKey.plexClientIdentifier)
            self.clientIdentifier = newId
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
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
        var request = URLRequest(url: URL(string: "\(Self.plexTVBaseURL)/api/v2/resources?includeHttps=1&includeRelay=1")!)
        request.httpMethod = "GET"
        addPlexHeaders(to: &request, token: token)

        let (data, _) = try await performRequest(request)
        let devices = try JSONDecoder().decode([PlexDevice].self, from: data)
        return devices.filter { $0.isServer }
    }

    /// Get user info
    public func getUserInfo(token: String) async throws -> PlexUser {
        var request = URLRequest(url: URL(string: "\(Self.plexTVBaseURL)/api/v2/user")!)
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

    /// Get all albums in a library section
    public func getAlbums(sectionKey: String) async throws -> [PlexAlbum] {
        let data = try await serverRequest(path: "/library/sections/\(sectionKey)/all", query: ["type": "9"])
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
            print("🔍 Raw JSON response (first 500 chars): \(String(jsonString.prefix(500)))")
        }
        
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        let track = container.mediaContainer.items.first
        
        if let track = track {
            print("🔍 getTrack - media count: \(track.media?.count ?? 0)")
            if let media = track.media?.first {
                print("🔍 getTrack - part count: \(media.part?.count ?? 0)")
                if let part = media.part?.first {
                    print("🔍 getTrack - part key: \(part.key ?? "nil")")
                    print("🔍 getTrack - part file: \(part.file ?? "nil")")
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

    /// Get audio playlists
    public func getPlaylists() async throws -> [PlexPlaylist] {
        let data = try await serverRequest(path: "/playlists", query: ["playlistType": "audio"])
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexPlaylist>.self,
            from: data
        )
        return container.mediaContainer.items
    }

    /// Get playlist tracks
    public func getPlaylistTracks(playlistKey: String) async throws -> [PlexTrack] {
        let data = try await serverRequest(path: "/playlists/\(playlistKey)/items")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items
    }
    
    // MARK: - Hubs (Home Screen Content)
    
    /// Get all hubs for a library section (Recently Added, Recently Played, etc.)
    public func getHubs(sectionKey: String) async throws -> [PlexHub] {
        let data = try await serverRequest(path: "/hubs/sections/\(sectionKey)")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexHub>.self,
            from: data
        )
        return container.mediaContainer.items
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

    // MARK: - URL Generation

    /// Generate streaming URL for a track using its stream key
    public func getStreamURL(trackKey: String?) throws -> URL {
        guard let partKey = trackKey, !partKey.isEmpty else {
            print("❌ PlexAPIClient: trackKey is nil or empty")
            throw PlexAPIError.invalidURL
        }

        print("🔍 PlexAPIClient: Building stream URL with partKey: \(partKey)")
        print("🔍 PlexAPIClient: Server URL: \(serverConnection.url)")
        
        guard var components = URLComponents(string: serverConnection.url) else {
            print("❌ PlexAPIClient: Failed to create URLComponents from server URL")
            throw PlexAPIError.invalidURL
        }
        
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            print("❌ PlexAPIClient: Failed to construct final URL")
            print("❌ PlexAPIClient: Components - path: \(components.path ?? "nil"), host: \(components.host ?? "nil")")
            throw PlexAPIError.invalidURL
        }

        print("✅ PlexAPIClient: Successfully created stream URL: \(url)")
        return url
    }

    /// Generate streaming URL for a track
    public func getStreamURL(for track: PlexTrack) throws -> URL {
        print("🔍 PlexAPIClient.getStreamURL(for track): \(track.title)")
        print("🔍 Track ratingKey: \(track.ratingKey)")
        print("🔍 Track media count: \(track.media?.count ?? 0)")
        
        if let media = track.media?.first {
            print("🔍 First media - parts count: \(media.part?.count ?? 0)")
            if let part = media.part?.first {
                print("🔍 First part key: \(part.key ?? "nil")")
            } else {
                print("❌ No parts in media")
            }
        } else {
            print("❌ No media array in track")
        }
        
        guard let partKey = track.media?.first?.part?.first?.key else {
            print("❌ Cannot extract part key from track")
            throw PlexAPIError.invalidURL
        }

        print("🔍 Building URL with partKey: \(partKey)")
        guard var components = URLComponents(string: serverConnection.url) else {
            print("❌ Failed to create URLComponents from server URL")
            throw PlexAPIError.invalidURL
        }
        
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            print("❌ Failed to construct final URL")
            throw PlexAPIError.invalidURL
        }

        print("✅ Successfully created stream URL: \(url)")
        return url
    }

    /// Generate artwork URL
    public func getArtworkURL(path: String?, size: Int = 300) throws -> URL? {
        guard let path = path else { return nil }

        var components = URLComponents(string: serverConnection.url)!
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

    // MARK: - Connection Management
    
    /// Attempt to find a working connection if current one fails
    private func attemptFailover() async throws {
        print("🔄 Attempting connection failover...")
        
        // Try to find the fastest working connection among all available URLs
        if let workingURL = await failoverManager.findFastestConnection(
            urls: serverConnection.allURLs,
            token: serverConnection.token
        ) {
            print("✅ Found working connection: \(workingURL)")
            currentServerURL = workingURL
        } else {
            print("❌ No working connections found")
            throw PlexAPIError.networkError(
                NSError(domain: "PlexAPIClient", code: -1, 
                       userInfo: [NSLocalizedDescriptionKey: "All server connections failed"])
            )
        }
    }
    
    /// Get the current active server URL
    public func getCurrentServerURL() -> String {
        currentServerURL
    }

    // MARK: - Private Methods

    private func serverRequest(path: String, query: [String: String] = [:]) async throws -> Data {
        // Try with current URL first
        do {
            return try await performServerRequest(url: currentServerURL, path: path, query: query)
        } catch {
            // If request fails and we have alternative URLs, attempt failover
            if !serverConnection.alternativeURLs.isEmpty {
                print("⚠️ Request failed with current URL, attempting failover...")
                try await attemptFailover()
                // Retry with new URL
                return try await performServerRequest(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }
    
    private func performServerRequest(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(string: url)!
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let (data, _) = try await performRequest(request)
        return data
    }
    
    private func serverRequestPUT(path: String, query: [String: String] = [:]) async throws -> Data {
        // Try with current URL first
        do {
            return try await performServerRequestPUT(url: currentServerURL, path: path, query: query)
        } catch {
            // If request fails and we have alternative URLs, attempt failover
            if !serverConnection.alternativeURLs.isEmpty {
                print("⚠️ PUT request failed with current URL, attempting failover...")
                try await attemptFailover()
                // Retry with new URL
                return try await performServerRequestPUT(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }
    
    private func performServerRequestPUT(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(string: url)!
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let (data, _) = try await performRequest(request)
        return data
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
    }
}
