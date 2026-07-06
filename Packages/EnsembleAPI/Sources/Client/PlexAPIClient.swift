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

/// Streaming quality options matching the AppStorage settings in SettingsView
public enum StreamingQuality: String, Sendable {
    case original = "original"
    case high = "high"        // 320 kbps
    case medium = "medium"    // 192 kbps
    case low = "low"          // 128 kbps
}

/// Configuration for progressive transcode streaming via AVAssetResourceLoaderDelegate.
/// Contains everything needed to start a URLSession data task and feed chunks to AVPlayer.
public struct ProgressiveStreamConfig: Sendable {
    public let streamRequest: URLRequest
    public let ratingKey: String
    public let estimatedContentLength: Int64
    public let metadataDuration: Double?
    public let startTime: TimeInterval

    public init(
        streamRequest: URLRequest,
        ratingKey: String,
        estimatedContentLength: Int64,
        metadataDuration: Double?,
        startTime: TimeInterval = 0
    ) {
        self.streamRequest = streamRequest
        self.ratingKey = ratingKey
        self.estimatedContentLength = estimatedContentLength
        self.metadataDuration = metadataDuration
        self.startTime = startTime
    }
}

/// Result of resolving how to stream a track — either a remote URL AVPlayer
/// can stream directly, a local file that was fully downloaded, or a progressive
/// transcode config for chunked streaming via resource loader delegate.
public enum StreamResolution: Sendable {
    case directStream(URL)                          // AVPlayer streams progressively from remote URL
    case downloadedFile(URL)                        // Full file downloaded locally (transcode was needed)
    case progressiveTranscode(ProgressiveStreamConfig)  // Chunked transcode via resource loader
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

/// Endpoint-independent streaming decision.
///
/// Captures what to stream (codec, quality, session) without baking in the server base URL.
/// Decisions survive network transitions and can be cached in PlaybackService; the server
/// endpoint is resolved fresh from ServerConnectionRegistry at assembly/download time.
///
/// Created by `makeStreamDecision()`, consumed by `assembleStreamResolution()`.
public enum StreamDecision: Sendable {
    /// Direct file stream — server says no transcoding needed.
    /// Part key (e.g., "/library/parts/8955/...") is resolved against the current endpoint at assembly time.
    case directStream(partKey: String)

    /// Progressive transcode — server will transcode on-the-fly.
    /// Query items contain session ID, quality, codec params. Assembled into a URLRequest at download time.
    case progressiveTranscode(TranscodeStreamDecision)
}

/// Parameters for a progressive transcode stream, without the base server URL.
/// Created by `makeStreamDecision()`, consumed by `assembleStreamResolution()`.
public struct TranscodeStreamDecision: Sendable {
    /// Transcode start path (e.g., "/music/:/transcode/universal/start.mp3")
    public let path: String
    /// All query params for the transcode request (session, quality, codec, auth, etc.)
    public let queryItems: [URLQueryItem]
    public let ratingKey: String
    public let estimatedContentLength: Int64
    public let metadataDuration: Double?
    public let startTime: TimeInterval

    public init(path: String, queryItems: [URLQueryItem], ratingKey: String,
                estimatedContentLength: Int64, metadataDuration: Double?, startTime: TimeInterval = 0) {
        self.path = path
        self.queryItems = queryItems
        self.ratingKey = ratingKey
        self.estimatedContentLength = estimatedContentLength
        self.metadataDuration = metadataDuration
        self.startTime = startTime
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

public struct PlexMetadataFieldUpdate: Sendable, Equatable {
    public let fieldName: String
    public let value: String?
    public let isLocked: Bool?

    public init(fieldName: String, value: String? = nil, isLocked: Bool? = nil) {
        self.fieldName = fieldName
        self.value = value
        self.isLocked = isLocked
    }
}

public actor PlexAPIClient {
    enum DownloadQueueError: LocalizedError {
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

    struct DownloadQueueEnvelope: Decodable {
        let MediaContainer: DownloadQueueMediaContainer
    }

    struct DownloadQueueMediaContainer: Decodable {
        let DownloadQueue: [DownloadQueueRecord]?
        let AddedQueueItems: [DownloadQueueAddedItem]?
        let DownloadQueueItem: [DownloadQueueItemRecord]?
    }

    struct DownloadQueueRecord: Decodable {
        let id: Int
    }

    struct DownloadQueueAddedItem: Decodable {
        let id: Int
    }

    struct DownloadQueueItemRecord: Decodable {
        let id: Int
        let status: String
        let error: String?
    }

    let session: URLSession
    let clientIdentifier: String
    let productName: String
    let productVersion: String
    let platformName: String
    let deviceName: String
    let failoverManager: ConnectionFailoverManager

    let serverConnection: PlexServerConnection
    let selectedLibrary: PlexLibrarySelection?
    var currentServerURL: String  // The currently active server URL
    private let isNetworkAvailable: @Sendable () async -> Bool

    // Centralized endpoint registry — when set, failover results are reported back
    let connectionRegistry: ServerConnectionRegistry?
    let serverKey: String?

    private static let plexTVBaseURL = "https://plex.tv"

    /// Initialize with a direct server connection
    /// - Parameters:
    ///   - connection: Server connection configuration
    ///   - librarySelection: Optional library selection
    ///   - keychain: Keychain for token persistence
    ///   - failoverManager: Manages connection failover probing
    ///   - connectionRegistry: Centralized endpoint registry — failover results are written back here
    ///   - serverKey: Registry key for this server (required when registry is provided)
    ///   - isNetworkAvailable: Device-level network availability gate for server requests
    ///   - productName: Client product name for Plex headers
    ///   - productVersion: Client product version for Plex headers
    public init(
        connection: PlexServerConnection,
        librarySelection: PlexLibrarySelection? = nil,
        keychain: KeychainServiceProtocol = KeychainService.shared,
        failoverManager: ConnectionFailoverManager = ConnectionFailoverManager(),
        connectionRegistry: ServerConnectionRegistry? = nil,
        serverKey: String? = nil,
        isNetworkAvailable: @escaping @Sendable () async -> Bool = { true },
        productName: String = "Ensemble",
        productVersion: String = "1.0"
    ) {
        self.serverConnection = connection
        self.selectedLibrary = librarySelection
        self.currentServerURL = connection.url
        self.failoverManager = failoverManager
        self.connectionRegistry = connectionRegistry
        self.serverKey = serverKey
        self.isNetworkAvailable = isNetworkAvailable
        self.productName = productName
        self.productVersion = productVersion
        self.platformName = PlexClientDeviceInfo.platformName
        self.deviceName = PlexClientDeviceInfo.defaultDeviceName()

        if let existingId = try? keychain.get(KeychainKey.plexClientIdentifier) {
            self.clientIdentifier = existingId
        } else {
            let newId = UUID().uuidString
            // try? is unavoidable in init (can't throw); log if it fails so we notice in debug builds
            if (try? keychain.save(newId, forKey: KeychainKey.plexClientIdentifier)) == nil {
                EnsembleLogger.debug("⚠️ [PlexAPIClient] Failed to persist client identifier to keychain")
            }
            self.clientIdentifier = newId
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15  // Reduced from 30s for faster failover on remote networks
        config.timeoutIntervalForResource = 120  // Keep resource timeout longer for large responses
        self.session = URLSession(configuration: config)
        
        let isHTTPS = connection.url.lowercased().hasPrefix("https://")
        let secureAlternativeCount = connection.alternativeURLs
            .filter { $0.lowercased().hasPrefix("https://") }
            .count
        EnsembleLogger.debug(
            "PlexAPIClient initialized primaryHTTPS=\(isHTTPS) alternatives=\(connection.alternativeURLs.count) secureAlternatives=\(secureAlternativeCount)"
        )

        // Seed the registry with the initial endpoint so consumers (e.g. WebSocket
        // coordinator) have a valid URL before the first health check completes.
        if let registry = connectionRegistry, let key = serverKey {
            let endpoint = connection.endpoints.first
                ?? PlexEndpointDescriptor(url: connection.url, local: false, relay: false)
            Task { await registry.updateEndpoint(for: key, endpoint: endpoint, source: .connectionRefresh) }
        }
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
        let request = try PlexRequestBuilder(
            baseURL: Self.plexTVBaseURL,
            token: token,
            headerContext: requestHeaderContext
        ).makeRequest(
            method: "GET",
            path: "/api/v2/user",
            includeTokenInQuery: false
        )

        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode(PlexUser.self, from: data)
    }

    // MARK: - Server API

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
        EnsembleLogger.debug("📊 Timeline reported: \(state) at \(time)ms / \(duration)ms for track \(ratingKey)")
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
        EnsembleLogger.debug("✅ Scrobbled track: \(ratingKey)")
    }

    // MARK: - Artwork & Audio Analysis

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
        EnsembleLogger.debug("🎵 Fetching loudness timeline for stream ID: \(streamId)")

        // Correct Plex API endpoint: /library/streams/{stream_id}/levels?subsample={count}
        // This returns loudness level data for waveform visualization
        let path = "/library/streams/\(streamId)/levels"
        let query = ["subsample": String(subsample)]

        do {
            let data = try await serverRequest(path: path, query: query)

            EnsembleLogger.debug("🔍 Received loudness response for stream \(streamId): \(data.count) bytes")

            let timeline = try JSONDecoder().decode(PlexLoudnessTimeline.self, from: data)

            if let count = timeline.loudness?.count {
                EnsembleLogger.debug("✅ Retrieved \(count) loudness samples for stream \(streamId)")
            } else {
                EnsembleLogger.debug("⚠️ No loudness data available for stream \(streamId)")
            }

            return timeline
        } catch {
            // If the endpoint doesn't exist (404), the server hasn't analyzed this track yet
            // This is normal and not an error condition
            EnsembleLogger.debug("ℹ️ Loudness timeline not available for stream \(streamId): \(error.localizedDescription)")
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
        // the shared Plex headers causes PMS to return JSON instead. We handle both formats.
        let query = ["format": "xml", "includeInlineAttribution": "1"]

        // Attempt fetch with retries — PMS may return 404 if its LyricFind cache
        // expired and needs a moment to re-fetch from the provider.
        // iOS 15 devices see more frequent 404s, so we use 3 attempts with longer delays.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let data = try await serverRequest(path: streamKey, query: query)

                EnsembleLogger.debug("Lyrics: content fetch succeeded for \(streamKey) on attempt \(attempt) (\(data.count) bytes)")

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
                let errorString = "\(error)"
                let isHTTP404 = errorString.contains("404")

                EnsembleLogger.debug("Lyrics: fetch failed for \(streamKey) (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription) [is404=\(isHTTP404)]")

                if isHTTP404 && attempt < maxAttempts {
                    // Increasing delay between retries — gives PMS time to re-fetch from LyricFind
                    let delaySeconds: UInt64 = attempt == 1 ? 2_000_000_000 : 3_000_000_000
                    try? await Task.sleep(nanoseconds: delaySeconds)
                    continue
                }
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
        EnsembleLogger.debug("\n🎵 PlexAPIClient.getSimilarTracks()")
        EnsembleLogger.debug("  - ratingKey: \(ratingKey)")
        EnsembleLogger.debug("  - limit: \(limit)")
        EnsembleLogger.debug("  - maxDistance: \(maxDistance)")

        let path = "/library/metadata/\(ratingKey)/nearest"
        let query = [
            "limit": String(limit),
            "maxDistance": String(maxDistance)
        ]
        EnsembleLogger.debug("  - path: \(path)")
        EnsembleLogger.debug("  - query: \(query)")

        do {
            EnsembleLogger.debug("🔄 Making serverRequest...")
            let data = try await serverRequest(path: path, query: query)
            EnsembleLogger.debug("✅ Received response data (\(data.count) bytes)")
            
            EnsembleLogger.debug("🔄 Decoding JSON...")
            let container = try JSONDecoder().decode(
                PlexMediaContainer<PlexTrack>.self,
                from: data
            )
            let tracks = container.mediaContainer.items
            EnsembleLogger.debug("✅ Successfully decoded \(tracks.count) PlexTrack objects")
            
            if tracks.isEmpty {
                EnsembleLogger.debug("⚠️ WARNING: API returned empty track list (no sonic analysis available)")
            } else {
                // Log first few results as confirmation
                for track in tracks.prefix(3) {
                    EnsembleLogger.debug("  ✅ Recommended: \(track.title) by \(track.grandparentTitle ?? "Unknown")")
                }
                if tracks.count > 3 {
                    EnsembleLogger.debug("  ... and \(tracks.count - 3) more tracks")
                }
            }
            
            return tracks
        } catch {
            EnsembleLogger.debug("❌ Error in getSimilarTracks:")
            EnsembleLogger.debug("   Type: \(type(of: error))")
            EnsembleLogger.debug("   Message: \(error.localizedDescription)")
            
            let nsError = error as NSError
            EnsembleLogger.debug("   NSError domain: \(nsError.domain)")
            EnsembleLogger.debug("   Code: \(nsError.code)")
            EnsembleLogger.debug("   UserInfo: \(nsError.userInfo)")
            
            // Check if it's a 404 (no sonic analysis)
            if let urlError = error as? URLError, urlError.code == .fileDoesNotExist {
                EnsembleLogger.debug("   → This is a 404: No sonic analysis available for this track")
            }
            
            return nil
        }
    }

    /// Fetch lyrics without XML/JSON transformation. Local sidecar chord files need
    /// their source whitespace preserved, and Plex's structured lyric response can
    /// strip the chord rows we need for alignment.
    public func getRawLyricsContent(streamKey: String) async throws -> String? {
        let query = ["format": "lrc"]
        do {
            let data = try await serverRequest(path: streamKey, query: query, accept: "text/plain")
            EnsembleLogger.debug("Lyrics: raw content fetch succeeded for \(streamKey) (\(data.count) bytes)")
            return String(data: data, encoding: .utf8)
        } catch {
            EnsembleLogger.debug("Lyrics: raw content fetch failed for \(streamKey): \(error.localizedDescription)")
            throw error
        }
    }

    /// Get artist radio station as a playlist
    /// Returns nil if artist radio not available or Plex Pass not active
    /// - Parameter artistKey: The artist's rating key
    public func getArtistRadioStation(artistKey: String) async throws -> PlexPlaylist? {
        EnsembleLogger.debug("🎵 PlexAPIClient.getArtistRadioStation() called")
        EnsembleLogger.debug("  - Artist key: \(artistKey)")
        EnsembleLogger.debug("🔄 Fetching artist radio station from Plex...")

        let path = "/library/metadata/\(artistKey)"
        let query = ["includeStations": "1"]
        EnsembleLogger.debug("  - Path: \(path)")
        EnsembleLogger.debug("  - Query: \(query)")

        do {
            EnsembleLogger.debug("🔄 Making serverRequest...")
            let data = try await serverRequest(path: path, query: query)
            EnsembleLogger.debug("✅ Got response data (\(data.count) bytes)")

            // The response includes a Stations container within the metadata
            // We need to parse it to extract the playlist
            EnsembleLogger.debug("🔄 Decoding response...")
            let container = try JSONDecoder().decode(
                PlexMediaContainer<PlexPlaylist>.self,
                from: data
            )
            EnsembleLogger.debug("✅ Decoded successfully, got \(container.mediaContainer.items.count) items")

            // Filter for station-type playlists
            let station = container.mediaContainer.items.first
            if let station = station {
                EnsembleLogger.debug("✅ Found artist radio station: \(station.title) (key: \(station.ratingKey))")
            } else {
                EnsembleLogger.debug("ℹ️ No artist radio station found for \(artistKey)")
            }
            return station
        } catch {
            EnsembleLogger.debug("❌ Artist radio not available for \(artistKey): \(error.localizedDescription)")
            return nil
        }
    }

    /// Get album radio station as a playlist
    /// Returns nil if album radio not available or Plex Pass not active
    /// - Parameter albumKey: The album's rating key
    public func getAlbumRadioStation(albumKey: String) async throws -> PlexPlaylist? {
        EnsembleLogger.debug("🎵 PlexAPIClient.getAlbumRadioStation() called")
        EnsembleLogger.debug("  - Album key: \(albumKey)")
        EnsembleLogger.debug("🔄 Fetching album radio station from Plex...")

        let path = "/library/metadata/\(albumKey)"
        let query = ["includeStations": "1"]
        EnsembleLogger.debug("  - Path: \(path)")
        EnsembleLogger.debug("  - Query: \(query)")

        do {
            EnsembleLogger.debug("🔄 Making serverRequest...")
            let data = try await serverRequest(path: path, query: query)
            EnsembleLogger.debug("✅ Got response data (\(data.count) bytes)")

            EnsembleLogger.debug("🔄 Decoding response...")
            let container = try JSONDecoder().decode(
                PlexMediaContainer<PlexPlaylist>.self,
                from: data
            )
            EnsembleLogger.debug("✅ Decoded successfully, got \(container.mediaContainer.items.count) items")

            let station = container.mediaContainer.items.first
            if let station = station {
                EnsembleLogger.debug("✅ Found album radio station: \(station.title) (key: \(station.ratingKey))")
            } else {
                EnsembleLogger.debug("ℹ️ No album radio station found for \(albumKey)")
            }
            return station
        } catch {
            EnsembleLogger.debug("❌ Album radio not available for \(albumKey): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Connection Management
    
    /// Attempt to find a policy-compliant working connection if current one fails.
    func attemptFailover() async throws -> ConnectionSelectionResult {
        guard await isNetworkAvailable() else {
            EnsembleLogger.debug("🔄 Connection failover skipped — device network unavailable")
            throw PlexAPIError.networkError(URLError(.notConnectedToInternet))
        }

        let startedAt = Date()
        EnsembleLogger.debug("🔄 Attempting connection failover...")

        let selection = await failoverManager.findBestConnection(
            endpoints: serverConnection.endpoints,
            token: serverConnection.token,
            selectionPolicy: serverConnection.selectionPolicy,
            allowInsecure: serverConnection.allowInsecurePolicy
        )
        let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())

        guard let endpoint = selection.selected else {
            EnsembleLogger.debug(
                "❌ No working connections found elapsedMs=\(elapsedMs) \(selection.diagnosticSummary)"
            )
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

        EnsembleLogger.debug(
            "✅ Found working connection elapsedMs=\(elapsedMs) \(endpointLogDescription(for: endpoint)) \(selection.diagnosticSummary)"
        )
        return selection
    }

    // MARK: - Private Methods

    func serverRequest(
        path: String,
        query: [String: String] = [:],
        accept: String = "application/json"
    ) async throws -> Data {
        try await ensureNetworkAvailableForServerRequest(path: path)
        await syncCurrentEndpointFromRegistryIfNeeded(reason: "GET request")

        // Try with current URL first
        do {
            return try await performServerRequest(url: currentServerURL, path: path, query: query, accept: accept)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            EnsembleLogger.debug("❌ Request failed: \(requestFailureLogDescription(error))")

            // Fail over only for transport/connectivity failures.
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                await recordCurrentEndpointFailure(error)
                EnsembleLogger.debug("⚠️ GET request failed with current endpoint, attempting failover...")
                _ = try await attemptFailover()
                // Retry with new URL
                return try await performServerRequest(url: currentServerURL, path: path, query: query, accept: accept)
            }
            throw error
        }
    }

    @discardableResult
    func syncCurrentEndpointFromRegistryIfNeeded(reason: String) async -> Bool {
        guard let registry = connectionRegistry,
              let key = serverKey,
              let state = await registry.currentState(for: key),
              state.endpoint.url != currentServerURL else {
            return false
        }

        await updateCurrentServerEndpoint(state.endpoint, source: state.source)
        EnsembleLogger.debug("📍 PlexAPIClient: Synced endpoint from registry before \(reason)")
        return true
    }

    private func recordCurrentEndpointFailure(_ error: Error) async {
        let transportError = transportError(from: error)
        guard shouldRecordCurrentEndpointFailure(transportError) else {
            return
        }

        let endpoint = serverConnection.endpoints.first { $0.url == currentServerURL }
            ?? PlexEndpointDescriptor(url: currentServerURL, local: false, relay: false)
        await failoverManager.recordConnectionFailure(endpoint: endpoint, error: transportError)
    }

    private func transportError(from error: Error) -> Error {
        if let plexError = error as? PlexAPIError,
           case .networkError(let underlying) = plexError {
            return underlying
        }
        return error
    }

    private func shouldRecordCurrentEndpointFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dataNotAllowed,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected:
            return true
        case .timedOut:
            return false
        default:
            return false
        }
    }
    
    var requestHeaderContext: PlexRequestHeaderContext {
        PlexRequestHeaderContext(
            clientIdentifier: clientIdentifier,
            productName: productName,
            productVersion: productVersion,
            platformName: platformName,
            deviceName: deviceName
        )
    }

    func performServerRequest(
        url: String,
        path: String,
        query: [String: String] = [:],
        accept: String = "application/json"
    ) async throws -> Data {
        let request = try PlexRequestBuilder(
            baseURL: url,
            token: serverConnection.token,
            headerContext: requestHeaderContext
        ).makeRequest(method: "GET", path: path, query: query, accept: accept)

        // Keep hot-path request logs URL-free so launch sync does not spend time redacting every line.
        let isHTTPS = url.lowercased().hasPrefix("https://")
        EnsembleLogger.debug(
            "📡 Request: \(request.httpMethod ?? "GET") pathLength=\(path.count) queryItems=\(query.count) endpointHTTPS=\(isHTTPS)"
        )

        let (data, _) = try await performRequest(request)
        return data
    }

    private func endpointLogDescription(for endpoint: PlexEndpointDescriptor) -> String {
        "class=\(endpoint.endpointClass.rawValue) local=\(endpoint.local ? 1 : 0) relay=\(endpoint.relay ? 1 : 0) secure=\(endpoint.secure ? 1 : 0)"
    }

    private func requestFailureLogDescription(_ error: Error) -> String {
        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .notAuthenticated:
                return "notAuthenticated"
            case .noServerSelected:
                return "noServerSelected"
            case .invalidURL:
                return "invalidURL"
            case .invalidResponse:
                return "invalidResponse"
            case .httpError(let statusCode):
                return "httpError(statusCode:\(statusCode))"
            case .decodingError(let underlying):
                return "decodingError(\(String(describing: type(of: underlying))))"
            case .networkError(let underlying):
                return "networkError(\(transportFailureLogDescription(underlying)))"
            }
        }

        return transportFailureLogDescription(error)
    }

    private func transportFailureLogDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(code:\(urlError.code.rawValue))"
        }

        let nsError = error as NSError
        return "NSError(domain:\(nsError.domain), code:\(nsError.code))"
    }
    
    func serverRequestPUT(path: String, query: [String: String] = [:]) async throws -> Data {
        try await ensureNetworkAvailableForServerRequest(path: path)
        await syncCurrentEndpointFromRegistryIfNeeded(reason: "PUT request")

        // Try with current URL first
        do {
            return try await performServerRequestPUT(url: currentServerURL, path: path, query: query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // If request fails and we have alternative URLs, attempt failover
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                await recordCurrentEndpointFailure(error)
                EnsembleLogger.debug("⚠️ PUT request failed with current endpoint, attempting failover...")
                _ = try await attemptFailover()
                // Retry with new URL
                return try await performServerRequestPUT(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }
    
    func performServerRequestPUT(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        let request = try PlexRequestBuilder(
            baseURL: url,
            token: serverConnection.token,
            headerContext: requestHeaderContext
        ).makeRequest(method: "PUT", path: path, query: query)

        let (data, _) = try await performRequest(request)
        return data
    }

    func serverRequestPOST(path: String, query: [String: String] = [:]) async throws -> Data {
        try await ensureNetworkAvailableForServerRequest(path: path)
        await syncCurrentEndpointFromRegistryIfNeeded(reason: "POST request")

        do {
            return try await performServerRequestPOST(url: currentServerURL, path: path, query: query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                await recordCurrentEndpointFailure(error)
                EnsembleLogger.debug("⚠️ POST request failed with current endpoint, attempting failover...")
                _ = try await attemptFailover()
                return try await performServerRequestPOST(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }

    func performServerRequestPOST(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        let request = try PlexRequestBuilder(
            baseURL: url,
            token: serverConnection.token,
            headerContext: requestHeaderContext
        ).makeRequest(method: "POST", path: path, query: query)

        let (data, _) = try await performRequest(request)
        return data
    }

    func serverRequestDELETE(path: String, query: [String: String] = [:]) async throws -> Data {
        try await ensureNetworkAvailableForServerRequest(path: path)
        await syncCurrentEndpointFromRegistryIfNeeded(reason: "DELETE request")

        do {
            return try await performServerRequestDELETE(url: currentServerURL, path: path, query: query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !serverConnection.alternativeURLs.isEmpty && shouldAttemptFailover(after: error) {
                await recordCurrentEndpointFailure(error)
                EnsembleLogger.debug("⚠️ DELETE request failed with current endpoint, attempting failover...")
                _ = try await attemptFailover()
                return try await performServerRequestDELETE(url: currentServerURL, path: path, query: query)
            }
            throw error
        }
    }

    func performServerRequestDELETE(url: String, path: String, query: [String: String] = [:]) async throws -> Data {
        let request = try makeServerRequest(url: url, method: "DELETE", path: path, query: query)
        let (data, _) = try await performRequest(request)
        return data
    }

    /// Build a server request with Plex auth headers and tokenized query.
    internal func makeServerRequest(
        url: String,
        method: String,
        path: String,
        query: [String: String] = [:],
        accept: String = "application/json"
    ) throws -> URLRequest {
        try PlexRequestBuilder(
            baseURL: url,
            token: serverConnection.token,
            headerContext: requestHeaderContext
        ).makeRequest(method: method, path: path, query: query, accept: accept)
    }

    internal func makeResourcesRequest(token: String) throws -> URLRequest {
        try PlexRequestBuilder(
            baseURL: Self.plexTVBaseURL,
            token: token,
            headerContext: requestHeaderContext
        ).makeRequest(
            method: "GET",
            path: "/api/v2/resources",
            query: [
                "includeHttps": "1",
                "includeRelay": "1",
                "includeIPv6": "1"
            ],
            includeTokenInQuery: false
        )
    }

    private func shouldAttemptFailover(after error: Error) -> Bool {
        PlexErrorClassification.classify(error).shouldFailover
    }

    private func ensureNetworkAvailableForServerRequest(path: String) async throws {
        guard await isNetworkAvailable() else {
            EnsembleLogger.debug("📴 Skipping Plex server request while device network unavailable: \(path)")
            throw PlexAPIError.networkError(URLError(.notConnectedToInternet))
        }
    }

    internal func shouldAttemptFailoverForTesting(after error: Error) -> Bool {
        shouldAttemptFailover(after: error)
    }

    internal func shouldRecordCurrentEndpointFailureForTesting(_ error: Error) -> Bool {
        shouldRecordCurrentEndpointFailure(error)
    }

    /// Build Plex metadata URI format used for playlist mutations.
    func buildMetadataURI(serverIdentifier: String, ratingKeys: [String]) -> String {
        let keys = ratingKeys.joined(separator: ",")
        return "server://\(serverIdentifier)/com.plexapp.plugins.library/library/metadata/\(keys)"
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Check if the task is already cancelled before making the request
        if Task.isCancelled {
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlexAPIError.networkError(error)
        }
    }

    func performRequestAllowingNon2xx(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlexAPIError.networkError(error)
        }
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
