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
/// endpoint is resolved from current authorized configuration at assembly/download time.
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

public struct PlexServerConnection: Sendable, Equatable {
    public let revision: UInt64
    public let routingGeneration: UInt64
    public let networkContext: NetworkReachabilityContext
    public let isDeviceOffline: Bool
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
        endpoints: [PlexEndpointDescriptor]? = nil,
        selectionPolicy: ConnectionSelectionPolicy = .plexSpecBalanced,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy = .sameNetwork,
        token: String,
        identifier: String,
        name: String,
        revision: UInt64 = 0,
        routingGeneration: UInt64 = 0,
        networkContext: NetworkReachabilityContext = .unknown,
        isDeviceOffline: Bool = false
    ) {
        self.revision = revision
        self.routingGeneration = routingGeneration
        self.networkContext = networkContext
        self.isDeviceOffline = isDeviceOffline
        self.url = url
        self.alternativeURLs = alternativeURLs
        if let endpoints {
            self.endpoints = endpoints
        } else {
            let primary = PlexEndpointDescriptor(url: url, local: false, relay: false)
            let alternatives = alternativeURLs.map { PlexEndpointDescriptor(url: $0, local: false, relay: false) }
            self.endpoints = [primary] + alternatives
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
        case itemFailed(String)
        case invalidQueueResponse

        var errorDescription: String? {
            switch self {
            case .queueNotAvailable:
                return "Download queue not available on this server"
            case .itemFailed(let reason):
                return "Download queue item failed: \(reason)"
            case .invalidQueueResponse:
                return "Invalid download queue response"
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
    var failoverManager: ConnectionFailoverManager
    let probeSession: URLSession
    public nonisolated let instanceID: UUID
    let configurationReader: (@Sendable () async -> PlexServerConnection?)?
    var isRetired = false
    var availability: PlexConnectionAvailability = .unknown
    var connectionFailureCategory: ConnectionProbeFailureCategory?
    var latestHealthEvidenceStartedAt: UInt64 = 0
    var connectionSequence: UInt64 = 0
    var connectionContinuations: [UUID: AsyncStream<PlexConnectionSnapshot>.Continuation] = [:]
    var lastPublishedConnectionSnapshot: PlexConnectionSnapshot?

    var serverConnection: PlexServerConnection
    let selectedLibrary: PlexLibrarySelection?
    var currentServerURL: String  // The currently active server URL
    // ponytail: prepared jobs survive interruptions in this process; persist IDs if relaunch preparation is costly.
    var interruptedDownloadQueueItems: [String: (queueId: Int, itemId: Int)] = [:]
    var cachedDownloadQueueID: Int?
    var downloadQueueIDTask: Task<Int, Error>?
    var downloadQueueItemCount = 0
    var downloadQueueStatusPollCount = 0
    var downloadQueueCacheHitCount = 0
    var downloadQueueCacheMissCount = 0
    let isNetworkAvailable: @Sendable () async -> Bool

    private static let plexTVBaseURL = "https://plex.tv"

    /// Initialize with a direct server connection
    /// - Parameters:
    ///   - connection: Server connection configuration
    ///   - librarySelection: Optional library selection
    ///   - keychain: Keychain for token persistence
    ///   - isNetworkAvailable: Device-level network availability gate for server requests
    ///   - productName: Client product name for Plex headers
    ///   - productVersion: Client product version for Plex headers
    public init(
        connection: PlexServerConnection,
        librarySelection: PlexLibrarySelection? = nil,
        keychain _: KeychainServiceProtocol = KeychainService.shared,
        userDefaults: UserDefaults = .standard,
        instanceID: UUID = UUID(),
        configurationReader: (@Sendable () async -> PlexServerConnection?)? = nil,
        probeURLSession: URLSession? = nil,
        isNetworkAvailable: @escaping @Sendable () async -> Bool = { true },
        productName: String = "Ensemble",
        productVersion: String = "1.0",
        urlSession: URLSession? = nil
    ) {
        self.serverConnection = connection
        self.selectedLibrary = librarySelection
        self.currentServerURL = connection.url
        let probeConfiguration = URLSessionConfiguration.default
        probeConfiguration.timeoutIntervalForRequest = 5
        probeConfiguration.timeoutIntervalForResource = 7
        let probeSession = probeURLSession ?? URLSession(configuration: probeConfiguration)
        self.probeSession = probeSession
        self.failoverManager = ConnectionFailoverManager(urlSession: probeSession)
        self.instanceID = instanceID
        self.configurationReader = configurationReader
        self.isNetworkAvailable = isNetworkAvailable
        self.productName = productName
        self.productVersion = productVersion
        self.platformName = PlexClientDeviceInfo.platformName
        self.deviceName = PlexClientDeviceInfo.defaultDeviceName()

        self.clientIdentifier = PlexAuthService.storedClientIdentifier(userDefaults: userDefaults)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15  // Reduced from 30s for faster failover on remote networks
        config.timeoutIntervalForResource = 120  // Keep resource timeout longer for large responses
        self.session = urlSession ?? URLSession(configuration: config)
        
        let isHTTPS = connection.url.lowercased().hasPrefix("https://")
        let secureAlternativeCount = connection.alternativeURLs
            .filter { $0.lowercased().hasPrefix("https://") }
            .count
        EnsembleLogger.debug(
            "PlexAPIClient initialized primaryHTTPS=\(isHTTPS) alternatives=\(connection.alternativeURLs.count) secureAlternatives=\(secureAlternativeCount)"
        )


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
    public func getArtworkURL(path: String?, size: Int = 300) async throws -> URL? {
        try await synchronizeConfiguration()
        guard !currentServerURL.isEmpty else { throw PlexAPIError.noServerSelected }
        return Self.artworkURL(
            serverURL: currentServerURL,
            token: serverConnection.token,
            path: path,
            size: size
        )
    }

    /// Generates an artwork URL without constructing a network client.
    public nonisolated static func artworkURL(
        serverURL: String,
        token: String,
        path: String?,
        size: Int = 300
    ) -> URL? {
        guard let path, var components = URLComponents(string: serverURL) else { return nil }

        components.path = "/photo/:/transcode"
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: String(size)),
            URLQueryItem(name: "height", value: String(size)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token)
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
    /// Returns the UTF-8 text content, or nil when PMS confirms the stream is absent.
    /// Fetch lyrics content for a given stream key.
    /// Uses format=xml (matching Plexamp). Only a confirmed 404 is unavailable;
    /// transient and server errors remain retryable failures.
    public func getLyricsContent(streamKey: String) async throws -> String? {
        // Plexamp fetches lyrics with format=xml; Accept: application/json from
        // the shared Plex headers causes PMS to return JSON instead. We handle both formats.
        let query = ["format": "xml", "includeInlineAttribution": "1"]

        do {
            let data = try await serverRequest(path: streamKey, query: query)
            if let text = Self.extractLyricsFromJSON(data) {
                return text
            }
            if let text = Self.extractLyricsFromXML(data) {
                return text
            }
            return String(data: data, encoding: .utf8)
        } catch where Self.isUnavailableLyricsResponse(error) {
            EnsembleLogger.debug("Lyrics: content unavailable for \(streamKey) (404)")
            return nil
        }
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

    /// Creates a fresh Plex Track Radio window and returns its recommendations.
    public func getTrackRadio(ratingKey: String) async throws -> [PlexTrack] {
        let stationID = UUID().uuidString.lowercased()
        let stationURI = "server://\(serverConnection.identifier)/com.plexapp.plugins.library/library/metadata/\(ratingKey)/station/\(stationID)?type=10&includeSharedContent=1&maxDegreesOfSeparation=-1"
        let data = try await serverRequestPOST(
            path: "/playQueues",
            query: ["type": "audio", "uri": stationURI]
        )
        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: data
        )
        return container.mediaContainer.items.filter { $0.ratingKey != ratingKey }
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
        } catch where Self.isUnavailableLyricsResponse(error) {
            EnsembleLogger.debug("Lyrics: raw content unavailable for \(streamKey) (404)")
            return nil
        } catch {
            EnsembleLogger.debug("Lyrics: raw content fetch failed for \(streamKey): \(error.localizedDescription)")
            throw error
        }
    }

    static func isUnavailableLyricsResponse(_ error: Error) -> Bool {
        guard case PlexAPIError.httpError(statusCode: 404) = error else { return false }
        return true
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

    // MARK: - Server requests

    func serverRequest(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        accept: String = "application/json",
        retryAfterFailover: Bool = true
    ) async throws -> Data {
        let attempt = try await authorizedServerAttempt()
        do {
            return try await performServerRequest(attempt, method: method, path: path, query: query, accept: accept)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let isCurrent = await recordServerAttemptFailure(attempt, error: error)
            guard retryAfterFailover, isCurrent,
                  serverConnection.endpoints.count > 1, shouldAttemptFailover(after: error) else { throw error }
            _ = try await attemptFailover(excluding: attempt.endpoint.url)
            let retry = try await authorizedServerAttempt()
            return try await performServerRequest(retry, method: method, path: path, query: query, accept: accept)
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

    private func performServerRequest(
        _ attempt: ServerAttempt,
        method: String,
        path: String,
        query: [String: String],
        accept: String
    ) async throws -> Data {
        let request = try makeServerRequest(
            url: attempt.endpoint.url, token: attempt.token,
            method: method, path: path, query: query, accept: accept
        )
        let (data, _) = try await performRequest(request)
        try await recordServerAttemptSuccess(attempt)
        return data
    }

    func serverRequestPUT(
        path: String,
        query: [String: String] = [:],
        retryAfterFailover: Bool = true
    ) async throws -> Data {
        try await serverRequest(method: "PUT", path: path, query: query, retryAfterFailover: retryAfterFailover)
    }

    func serverRequestPOST(
        path: String,
        query: [String: String] = [:],
        retryAfterFailover: Bool = true
    ) async throws -> Data {
        try await serverRequest(method: "POST", path: path, query: query, retryAfterFailover: retryAfterFailover)
    }

    func serverRequestDELETE(
        path: String,
        query: [String: String] = [:],
        retryAfterFailover: Bool = true
    ) async throws -> Data {
        try await serverRequest(method: "DELETE", path: path, query: query, retryAfterFailover: retryAfterFailover)
    }

    /// Build a server request with Plex auth headers and tokenized query.
    internal func makeServerRequest(
        url: String,
        token: String? = nil,
        method: String,
        path: String,
        query: [String: String] = [:],
        accept: String = "application/json"
    ) throws -> URLRequest {
        try PlexRequestBuilder(
            baseURL: url,
            token: token ?? serverConnection.token,
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

    func shouldAttemptFailover(after error: Error) -> Bool {
        PlexErrorClassification.classify(error).shouldFailover
    }

    /// Build Plex metadata URI format used for playlist mutations.
    func buildMetadataURI(serverIdentifier: String, ratingKeys: [String]) -> String {
        let keys = ratingKeys.joined(separator: ",")
        return "server://\(serverIdentifier)/com.plexapp.plugins.library/library/metadata/\(keys)"
    }

    func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
