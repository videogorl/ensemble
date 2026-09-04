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
        metadataDurationSeconds: Double?,
        startTime: TimeInterval = 0
    ) async throws -> StreamDecision {
        let normalizedStartTime = Self.normalizedTranscodeOffset(startTime)
        if normalizedStartTime == 0, quality == .original, let streamKey = trackStreamKey, !streamKey.isEmpty {
            if let track = try? await getTrack(trackKey: ratingKey),
               PlexAudioFormatSupport.supportsIncrementalPlayback(track) {
                EnsembleLogger.debug("[makeStreamDecision] compatible original → directStream(partKey)")
                return .directStream(partKey: streamKey)
            }
            EnsembleLogger.debug("[makeStreamDecision] original requires PMS capability decision")
        }

        if let streamKey = trackStreamKey, !streamKey.isEmpty {
            let sessionId = UUID().uuidString
            let queryItems = buildUniversalStreamQueryItems(
                ratingKey: ratingKey,
                quality: quality,
                sessionId: sessionId,
                startTime: normalizedStartTime
            )

            let decision = try await callTranscodeDecision(queryItems: queryItems)

            switch decision.decision {
            case .directplay where normalizedStartTime == 0,
                 .copy where normalizedStartTime == 0:
                let partKey = decision.directStreamPartKey ?? streamKey
                EnsembleLogger.debug("[makeStreamDecision] decision=\(decision.decision.rawValue) → directStream(partKey)")
                return .directStream(partKey: partKey)

            case .directplay, .copy, .transcode, .unknown:
                let estimated = estimateTranscodeSize(quality: quality, durationSeconds: metadataDurationSeconds)
                EnsembleLogger.debug("[makeStreamDecision] decision=\(decision.decision.rawValue) → progressiveTranscode")
                return .progressiveTranscode(TranscodeStreamDecision(
                    path: "/music/:/transcode/universal/start.mp3",
                    queryItems: queryItems,
                    ratingKey: ratingKey,
                    estimatedContentLength: estimated,
                    metadataDuration: metadataDurationSeconds,
                    startTime: normalizedStartTime
                ))
            }
        }

        let sessionId = UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: sessionId,
            startTime: normalizedStartTime
        )
        try await callTranscodeDecision(queryItems: queryItems)
        let estimated = estimateTranscodeSize(quality: quality, durationSeconds: metadataDurationSeconds)
        EnsembleLogger.debug("[makeStreamDecision] no stream key → progressiveTranscode")
        return .progressiveTranscode(TranscodeStreamDecision(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems,
            ratingKey: ratingKey,
            estimatedContentLength: estimated,
            metadataDuration: metadataDurationSeconds,
            startTime: normalizedStartTime
        ))
    }

    /// Phase 2: Assemble a `StreamResolution` from a `StreamDecision` using the current server endpoint.
    public func assembleStreamResolution(from decision: StreamDecision) async throws -> StreamResolution {
        await syncCurrentEndpointFromRegistryIfNeeded(reason: "stream assembly")

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
            requestHeaderContext.apply(to: &request, token: serverConnection.token)
            request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")

            let config = ProgressiveStreamConfig(
                streamRequest: request,
                ratingKey: transcode.ratingKey,
                estimatedContentLength: transcode.estimatedContentLength,
                metadataDuration: transcode.metadataDuration,
                startTime: transcode.startTime
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
        sessionId: String,
        startTime: TimeInterval = 0
    ) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: Self.transcodeOffsetValue(startTime)),
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

    static func normalizedTranscodeOffset(_ startTime: TimeInterval) -> TimeInterval {
        guard startTime.isFinite, startTime > 0 else { return 0 }
        return floor(startTime)
    }

    static func transcodeOffsetValue(_ startTime: TimeInterval) -> String {
        String(Int(normalizedTranscodeOffset(startTime)))
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
        await syncCurrentEndpointFromRegistryIfNeeded(reason: "transcode decision")

        var didRetry = false
        while true {
            let url = try buildTranscodeURL(
                path: "/music/:/transcode/universal/decision",
                queryItems: queryItems
            )

            EnsembleLogger.debug("🔄 Calling transcode decision endpoint")

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            requestHeaderContext.apply(to: &request, token: serverConnection.token)
            request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")

            do {
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !didRetry,
                      !serverConnection.alternativeURLs.isEmpty,
                      shouldAttemptFailover(after: error) else {
                    throw error
                }

                didRetry = true
                let failedURL = currentServerURL
                await recordCurrentEndpointFailure(error)
                EnsembleLogger.debug("⚠️ Transcode decision failed with current endpoint, attempting failover...")
                _ = try await attemptFailover(excluding: failedURL)
            }
        }
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
        let directPlay = PlexAudioFormatSupport.directPlayCodecs.map {
            "add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=\($0))"
        }
        return ([
            "add-transcode-target-codec(type=musicProfile&context=streaming&protocol=http&audioCodec=mp3)",
        ] + directPlay).joined(separator: "+")
    }
}
