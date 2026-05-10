import Foundation

extension PlexAPIClient {
    // MARK: - Playback URLs

    /// Generate streaming URL for a track using its stream key.
    public func getStreamURL(trackKey: String?) throws -> URL {
        guard let partKey = trackKey, !partKey.isEmpty else {
            EnsembleLogger.debug("❌ PlexAPIClient: trackKey is nil or empty")
            throw PlexAPIError.invalidURL
        }

        EnsembleLogger.debug("🔍 PlexAPIClient: Building stream URL with partKey: \(partKey)")
        EnsembleLogger.debug("🔍 PlexAPIClient: Current server URL: \(currentServerURL)")

        guard var components = URLComponents(string: currentServerURL) else {
            EnsembleLogger.debug("❌ PlexAPIClient: Failed to create URLComponents from current server URL")
            throw PlexAPIError.invalidURL
        }

        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]

        guard let url = components.url else {
            EnsembleLogger.debug("❌ PlexAPIClient: Failed to construct final URL")
            EnsembleLogger.debug("❌ PlexAPIClient: Components - path: \(components.path), host: \(components.host ?? "nil")")
            throw PlexAPIError.invalidURL
        }

        EnsembleLogger.debug("✅ PlexAPIClient: Successfully created stream URL: \(url)")
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

    /// Generate a transcode URL with endpoint and path-shape fallbacks.
    public func getTranscodeStreamURL(
        trackKey: String,
        quality: StreamingQuality,
        useAbsolutePathParameter: Bool,
        useAudioEndpoint: Bool,
        useStartWithoutExtension: Bool
    ) async throws -> URL {
        EnsembleLogger.debug("🎵 PlexAPIClient.getTranscodeStreamURL: \(trackKey) [quality: \(quality.rawValue)]")

        guard var components = URLComponents(string: currentServerURL) else {
            throw PlexAPIError.invalidURL
        }

        components.path = transcodeStartPath(
            useAudioEndpoint: useAudioEndpoint,
            useStartWithoutExtension: useStartWithoutExtension
        )

        let bitrate: String
        switch quality {
        case .original:
            bitrate = "320"
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
            URLQueryItem(name: "musicBitrate", value: bitrate),
            URLQueryItem(name: "audioBitrate", value: bitrate),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "X-Plex-Token", value: serverConnection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier)
        ]
        queryItems.append(contentsOf: transcodeClientQueryItems(sessionId: sessionId))
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

        EnsembleLogger.debug("🎵 PlexAPIClient.getTranscodeStreamURL normalized path: \(normalizedPath)")
        EnsembleLogger.debug("✅ Created transcode stream URL: \(url)")

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

    /// Get a universal stream URL for a track.
    /// Delegates to the ratingKey overload which handles the decision endpoint call.
    public func getUniversalStreamURL(
        for track: PlexTrack,
        quality: StreamingQuality = .original,
        sessionId: String? = nil
    ) async throws -> URL {
        EnsembleLogger.debug("🎵 PlexAPIClient.getUniversalStreamURL: \(track.title) [quality: \(quality.rawValue)]")
        return try await getUniversalStreamURL(
            ratingKey: track.ratingKey,
            quality: quality,
            sessionId: sessionId
        )
    }

    /// Get a universal stream URL for a track, warming up the transcode session first.
    /// The decision endpoint MUST be called before start.mp3 or PMS returns 400.
    public func getUniversalStreamURL(
        ratingKey: String,
        quality: StreamingQuality = .original,
        sessionId: String? = nil
    ) async throws -> URL {
        EnsembleLogger.debug("🎵 PlexAPIClient.getUniversalStreamURL(ratingKey): \(ratingKey) [quality: \(quality.rawValue)]")

        let resolvedSessionId = sessionId ?? UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: resolvedSessionId
        )

        try await callTranscodeDecision(queryItems: queryItems)

        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        EnsembleLogger.debug("✅ Created universal stream URL")

        return url
    }

    /// Resolve the best streaming approach for a track.
    ///
    /// Convenience method that chains `makeStreamDecision()` → `assembleStreamResolution()`.
    public func resolveStreamURL(
        ratingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution {
        let decision = try await makeStreamDecision(
            ratingKey: ratingKey,
            trackStreamKey: trackStreamKey,
            quality: quality,
            metadataDurationSeconds: metadataDurationSeconds
        )
        return try await assembleStreamResolution(from: decision)
    }

    // MARK: - Two-Phase Stream Resolution

    /// Phase 1: Make a streaming decision without embedding the server endpoint URL.
    public func makeStreamDecision(
        ratingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamDecision {
        if quality == .original, let streamKey = trackStreamKey, !streamKey.isEmpty {
            EnsembleLogger.debug("[makeStreamDecision] original quality → directStream(partKey)")
            return .directStream(partKey: streamKey)
        }

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
                let partKey = decision.directStreamPartKey ?? streamKey
                EnsembleLogger.debug("[makeStreamDecision] decision=\(decision.decision.rawValue) → directStream(partKey)")
                return .directStream(partKey: partKey)

            case .transcode, .unknown:
                let estimated = estimateTranscodeSize(quality: quality, durationSeconds: metadataDurationSeconds)
                EnsembleLogger.debug("[makeStreamDecision] decision=\(decision.decision.rawValue) → progressiveTranscode")
                return .progressiveTranscode(TranscodeStreamDecision(
                    path: "/music/:/transcode/universal/start.mp3",
                    queryItems: queryItems,
                    ratingKey: ratingKey,
                    estimatedContentLength: estimated,
                    metadataDuration: metadataDurationSeconds
                ))
            }
        }

        let sessionId = UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: sessionId
        )
        try await callTranscodeDecision(queryItems: queryItems)
        let estimated = estimateTranscodeSize(quality: quality, durationSeconds: metadataDurationSeconds)
        EnsembleLogger.debug("[makeStreamDecision] no stream key → progressiveTranscode")
        return .progressiveTranscode(TranscodeStreamDecision(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems,
            ratingKey: ratingKey,
            estimatedContentLength: estimated,
            metadataDuration: metadataDurationSeconds
        ))
    }

    /// Phase 2: Assemble a `StreamResolution` from a `StreamDecision` using the current server endpoint.
    public func assembleStreamResolution(from decision: StreamDecision) async throws -> StreamResolution {
        if let registry = connectionRegistry, let key = serverKey,
           let freshURL = await registry.currentURL(for: key) {
            if freshURL != currentServerURL {
                EnsembleLogger.debug("[assembleStream] Endpoint synced from registry: \(currentServerURL) → \(freshURL)")
                currentServerURL = freshURL
            }
        }

        switch decision {
        case .directStream(let partKey):
            let url = try getStreamURL(trackKey: partKey)
            EnsembleLogger.debug("[assembleStream] directStream → \(url)")
            return .directStream(url)

        case .progressiveTranscode(let transcode):
            let url = try buildTranscodeURL(path: transcode.path, queryItems: transcode.queryItems)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            addPlexHeaders(to: &request, token: serverConnection.token)
            request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")

            let config = ProgressiveStreamConfig(
                streamRequest: request,
                ratingKey: transcode.ratingKey,
                estimatedContentLength: transcode.estimatedContentLength,
                metadataDuration: transcode.metadataDuration
            )
            EnsembleLogger.debug("[assembleStream] progressiveTranscode → \(url)")
            return .progressiveTranscode(config)
        }
    }

    // MARK: - Playback Helpers

    /// Build query items for universal transcode endpoints (shared by decision and start).
    func buildUniversalStreamQueryItems(
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

    /// Build a URLRequest for the start.mp3 transcode endpoint with Plex headers.
    func buildProgressiveStreamConfig(
        ratingKey: String,
        quality: StreamingQuality,
        queryItems: [URLQueryItem],
        metadataDuration metadataDurationSeconds: Double?
    ) throws -> ProgressiveStreamConfig {
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        addPlexHeaders(to: &request, token: serverConnection.token)
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")

        let estimatedLength = estimateTranscodeSize(
            quality: quality,
            durationSeconds: metadataDurationSeconds
        )

        return ProgressiveStreamConfig(
            streamRequest: request,
            ratingKey: ratingKey,
            estimatedContentLength: estimatedLength,
            metadataDuration: metadataDurationSeconds
        )
    }

    /// Estimate the download size of a transcode based on quality bitrate and duration.
    func estimateTranscodeSize(quality: StreamingQuality, durationSeconds: Double?) -> Int64 {
        let duration = durationSeconds ?? 240
        let bitrateKbps: Double
        switch quality {
        case .original: bitrateKbps = 320
        case .high: bitrateKbps = 320
        case .medium: bitrateKbps = 192
        case .low: bitrateKbps = 128
        }
        return Int64(bitrateKbps / 8.0 * duration * 1024.0 * 1.1)
    }

    /// Call the transcode decision endpoint to warm up the session and parse PMS's decision.
    @discardableResult
    func callTranscodeDecision(queryItems: [URLQueryItem]) async throws -> TranscodeDecisionResult {
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/decision",
            queryItems: queryItems
        )

        EnsembleLogger.debug("🔄 Calling transcode decision endpoint")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addPlexHeaders(to: &request, token: serverConnection.token)
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            EnsembleLogger.debug("⚠️ Transcode decision returned \(httpResponse.statusCode)")
            throw PlexAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        let result = parseTranscodeDecision(from: data)

        EnsembleLogger.debug("✅ Transcode decision completed: \(result.decision.rawValue), partKey: \(result.directStreamPartKey ?? "nil")")

        return result
    }

    /// Parse the transcode decision JSON into a structured result.
    func parseTranscodeDecision(from data: Data) -> TranscodeDecisionResult {
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
    func buildTranscodeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
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

    func transcodeClientQueryItems(sessionId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionId),
            URLQueryItem(name: "transcodeSessionId", value: sessionId),
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "X-Plex-Product", value: productName),
            URLQueryItem(name: "X-Plex-Platform", value: "iOS"),
            URLQueryItem(name: "X-Plex-Device", value: deviceName),
            URLQueryItem(name: "X-Plex-Device-Name", value: deviceName),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: transcodeClientProfileExtra()),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "hasMDE", value: "1")
        ]
    }

    func transcodeClientProfileExtra() -> String {
        [
            "add-transcode-target-codec(type=musicProfile&context=streaming&protocol=http&audioCodec=mp3)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=aac)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=mp3)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=flac)",
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=alac)",
        ].joined(separator: "+")
    }

    func transcodeStartPath(
        useAudioEndpoint: Bool,
        useStartWithoutExtension: Bool
    ) -> String {
        let transcodeType = useAudioEndpoint ? "audio" : "music"
        let startComponent = useStartWithoutExtension ? "start" : "start.mp3"
        return "/\(transcodeType)/:/transcode/universal/\(startComponent)"
    }

}
