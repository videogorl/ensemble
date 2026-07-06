import Foundation

extension PlexAPIClient {
    // MARK: - Download Endpoints

    /// Download transcoded media using Plex's download queue flow.
    /// This primes server-side transcode before media retrieval.
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

        EnsembleLogger.debug(
            "⬇️ DownloadQueue enqueued: queue=\(queueId) item=\(itemId) track=\(trackRatingKey) quality=\(quality.rawValue)"
        )

        let timeoutDeadline = Date().addingTimeInterval(120)
        var pollInterval: UInt64 = 1_000_000_000
        let maxPollInterval: UInt64 = 15_000_000_000
        while Date() < timeoutDeadline {
            try Task.checkCancellation()

            let item: DownloadQueueItemRecord
            do {
                item = try await getDownloadQueueItem(queueId: queueId, itemId: itemId)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where [
                .notConnectedToInternet, .networkConnectionLost,
                .dataNotAllowed, .internationalRoamingOff
            ].contains(urlError.code) {
                throw urlError
            } catch {
                try await Task.sleep(nanoseconds: pollInterval)
                pollInterval = min(pollInterval * 2, maxPollInterval)
                continue
            }

            switch item.status {
            case "available":
                return try await fetchDownloadQueueMedia(queueId: queueId, itemId: itemId)
            case "error":
                throw DownloadQueueError.itemFailed(item.error ?? "Unknown queue error")
            case "expired":
                try await restartDownloadQueueItem(queueId: queueId, itemId: itemId)
                try await Task.sleep(nanoseconds: pollInterval)
            case "deciding", "waiting", "processing":
                try await Task.sleep(nanoseconds: pollInterval)
            default:
                try await Task.sleep(nanoseconds: pollInterval)
            }
            pollInterval = min(pollInterval * 2, maxPollInterval)
        }

        throw DownloadQueueError.itemProcessingTimedOut
    }

    /// Download a universal transcode stream to a temporary file and return the file URL.
    public func downloadUniversalStreamToFile(
        ratingKey: String,
        quality: StreamingQuality = .original,
        sessionId: String? = nil
    ) async throws -> URL {
        EnsembleLogger.debug("🎵 PlexAPIClient.downloadUniversalStreamToFile(ratingKey): \(ratingKey) [quality: \(quality.rawValue)]")

        let resolvedSessionId = sessionId ?? UUID().uuidString
        let queryItems = buildUniversalStreamQueryItems(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: resolvedSessionId
        )

        try await callTranscodeDecision(queryItems: queryItems)
        return try await downloadUniversalStreamFile(
            ratingKey: ratingKey,
            quality: quality,
            sessionId: resolvedSessionId,
            queryItems: queryItems,
            logOriginalContentType: true,
            unknownContentTypeContext: "original quality stream",
            successLogPrefix: "Downloaded universal stream to file:"
        )
    }

    private func downloadUniversalStreamFile(
        ratingKey: String,
        quality: StreamingQuality,
        sessionId: String,
        queryItems: [URLQueryItem],
        logOriginalContentType: Bool,
        unknownContentTypeContext: String,
        successLogPrefix: String
    ) async throws -> URL {
        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        EnsembleLogger.debug("🔗 Downloading universal stream for ratingKey \(ratingKey) [session: \(sessionId.prefix(8))]")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        requestHeaderContext.apply(to: &request, token: serverConnection.token)
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")

        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            EnsembleLogger.debug("⚠️ Universal stream download returned \(statusCode)")
            throw PlexAPIError.httpError(statusCode: statusCode)
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let fileExtension: String
        if quality != .original {
            fileExtension = "mp3"
        } else {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            fileExtension = Self.universalStreamFileExtension(
                quality: quality,
                contentType: contentType
            )
            if fileExtension == "audio" {
                EnsembleLogger.debug("⚠️ Unknown Content-Type for \(unknownContentTypeContext): '\(contentType)'")
            }
            if logOriginalContentType {
                EnsembleLogger.debug("📦 Original quality Content-Type: '\(contentType)' → .\(fileExtension)")
            }
        }

        let destURL = cacheDir.appendingPathComponent("\(ratingKey)_\(sessionId).\(fileExtension)")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        EnsembleLogger.debug("\(successLogPrefix) \(destURL.lastPathComponent) (\(fileSize) bytes)")

        return destURL
    }

    static func universalStreamFileExtension(quality: StreamingQuality, contentType: String) -> String {
        guard quality == .original else { return "mp3" }

        let normalizedContentType = contentType.lowercased()
        switch normalizedContentType {
        case let contentType where contentType.contains("flac"):
            return "flac"
        case let contentType where contentType.contains("mp4") || contentType.contains("m4a"):
            return "m4a"
        case let contentType where contentType.contains("mpeg") || contentType.contains("mp3"):
            return "mp3"
        case let contentType where contentType.contains("wav"):
            return "wav"
        case let contentType where contentType.contains("aac"):
            return "aac"
        default:
            return "audio"
        }
    }

    /// Build a universal download URL for offline use, skipping the decision endpoint.
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

        let url = try buildTranscodeURL(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: queryItems
        )

        EnsembleLogger.debug("✅ Created universal download URL (no decision): ratingKey=\(ratingKey) quality=\(quality.rawValue)")

        return url
    }

    // MARK: - Download Queue Helpers

    func getOrCreateDownloadQueueID() async throws -> Int {
        let data = try await serverRequestPOST(path: "/downloadQueue")
        let decoded = try JSONDecoder().decode(DownloadQueueEnvelope.self, from: data)
        guard let queueId = decoded.MediaContainer.DownloadQueue?.first?.id else {
            throw DownloadQueueError.invalidQueueResponse
        }
        return queueId
    }

    func addDownloadQueueItem(
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

    func getDownloadQueueItem(queueId: Int, itemId: Int) async throws -> DownloadQueueItemRecord {
        let data = try await serverRequest(path: "/downloadQueue/\(queueId)/items/\(itemId)")
        let decoded = try JSONDecoder().decode(DownloadQueueEnvelope.self, from: data)
        guard let item = decoded.MediaContainer.DownloadQueueItem?.first else {
            throw DownloadQueueError.invalidQueueResponse
        }
        return item
    }

    func restartDownloadQueueItem(queueId: Int, itemId: Int) async throws {
        _ = try await serverRequestPOST(path: "/downloadQueue/\(queueId)/items/\(itemId)/restart")
    }

    func fetchDownloadQueueMedia(
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

    func downloadQueueBitrate(for quality: StreamingQuality) -> String? {
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
}
