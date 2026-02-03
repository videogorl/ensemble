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
    public let token: String
    public let identifier: String
    public let name: String

    public init(url: String, token: String, identifier: String, name: String) {
        self.url = url
        self.token = token
        self.identifier = identifier
        self.name = name
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

    private let serverConnection: PlexServerConnection
    private let selectedLibrary: PlexLibrarySelection?

    private static let plexTVBaseURL = "https://plex.tv"

    /// Initialize with a direct server connection
    public init(connection: PlexServerConnection, librarySelection: PlexLibrarySelection? = nil, keychain: KeychainServiceProtocol = KeychainService.shared) {
        self.keychain = keychain
        self.serverConnection = connection
        self.selectedLibrary = librarySelection

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
        let data = try await serverRequest(path: "/library/sections/\(sectionKey)/all", query: ["type": "10"])
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

    /// Get a single track
    public func getTrack(trackKey: String) async throws -> PlexTrack? {
        let data = try await serverRequest(path: "/library/metadata/\(trackKey)")
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items.first
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

    // MARK: - URL Generation

    /// Generate streaming URL for a track using its stream key
    public func getStreamURL(trackKey: String?) throws -> URL {
        guard let partKey = trackKey else {
            throw PlexAPIError.invalidURL
        }

        var components = URLComponents(string: serverConnection.url)!
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        return url
    }

    /// Generate streaming URL for a track
    public func getStreamURL(for track: PlexTrack) throws -> URL {
        guard let partKey = track.media?.first?.part?.first?.key else {
            throw PlexAPIError.invalidURL
        }

        var components = URLComponents(string: serverConnection.url)!
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

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

    // MARK: - Private Methods

    private func serverRequest(path: String, query: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(string: serverConnection.url)!
        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: serverConnection.token))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
