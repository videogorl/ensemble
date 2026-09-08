import Foundation

extension PlexAPIClient {
    // MARK: - Download Endpoints

    /// Download transcoded media using Plex's download queue flow.
    /// This primes server-side transcode before media retrieval.
    /// The caller owns the returned temporary file and must move or remove it.
    public func downloadTranscodedMediaViaQueue(
        trackRatingKey: String,
        quality: StreamingQuality
    ) async throws -> (fileURL: URL, suggestedFilename: String?, mimeType: String?) {
        guard quality != .original else {
            throw DownloadQueueError.queueNotAvailable
        }

        let metadataKey = "/library/metadata/\(trackRatingKey)"
        let jobKey = "\(metadataKey)|\(quality.rawValue)"
        let (queueId, itemId): (Int, Int)
        if let job = interruptedDownloadQueueItems[jobKey] {
            (queueId, itemId) = job
        } else {
            (queueId, itemId) = try await enqueueDownloadQueueItem(metadataKey: metadataKey, quality: quality)
            interruptedDownloadQueueItems[jobKey] = (queueId, itemId)
        }

        let timeoutDeadline = Date().addingTimeInterval(120)
        var pollInterval: UInt64 = 1_000_000_000
        let maxPollInterval: UInt64 = 15_000_000_000
        var statusPollCount = 0
        defer { recordDownloadQueueTelemetry(statusPollCount: statusPollCount) }
        while Date() < timeoutDeadline {
            try Task.checkCancellation()

            let item: DownloadQueueItemRecord
            do {
                statusPollCount += 1
                item = try await getDownloadQueueItem(queueId: queueId, itemId: itemId)
            } catch PlexAPIError.httpError(statusCode: 404) {
                interruptedDownloadQueueItems.removeValue(forKey: jobKey)
                throw URLError(.timedOut)
            }

            switch item.status {
            case "available":
                let result = try await fetchDownloadQueueMedia(queueId: queueId, itemId: itemId)
                interruptedDownloadQueueItems.removeValue(forKey: jobKey)
                return result
            case "error":
                interruptedDownloadQueueItems.removeValue(forKey: jobKey)
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

        throw URLError(.timedOut)
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
        if let cachedDownloadQueueID {
            downloadQueueCacheHitCount += 1
            return cachedDownloadQueueID
        }
        if let downloadQueueIDTask {
            downloadQueueCacheHitCount += 1
            return try await downloadQueueIDTask.value
        }

        downloadQueueCacheMissCount += 1
        let task = Task { try await fetchDownloadQueueID() }
        downloadQueueIDTask = task
        do {
            let queueId = try await task.value
            cachedDownloadQueueID = queueId
            downloadQueueIDTask = nil
            return queueId
        } catch {
            downloadQueueIDTask = nil
            throw error
        }
    }

    private func fetchDownloadQueueID() async throws -> Int {
        let data = try await serverRequestPOST(path: "/downloadQueue")
        let decoded = try JSONDecoder().decode(DownloadQueueEnvelope.self, from: data)
        guard let queueId = decoded.MediaContainer.DownloadQueue?.first?.id else {
            throw DownloadQueueError.invalidQueueResponse
        }
        return queueId
    }

    func enqueueDownloadQueueItem(
        metadataKey: String,
        quality: StreamingQuality
    ) async throws -> (queueId: Int, itemId: Int) {
        var queueId = try await getOrCreateDownloadQueueID()
        do {
            let itemId = try await addDownloadQueueItem(
                queueId: queueId,
                metadataKey: metadataKey,
                quality: quality
            )
            return (queueId, itemId)
        } catch let error as PlexAPIError {
            guard case .httpError(statusCode: 404) = error else { throw error }
            cachedDownloadQueueID = nil
            queueId = try await getOrCreateDownloadQueueID()
            let itemId = try await addDownloadQueueItem(
                queueId: queueId,
                metadataKey: metadataKey,
                quality: quality
            )
            return (queueId, itemId)
        }
    }

    func recordDownloadQueueTelemetry(statusPollCount: Int) {
        downloadQueueItemCount += 1
        downloadQueueStatusPollCount += statusPollCount
        guard downloadQueueItemCount == 1 || downloadQueueItemCount.isMultiple(of: 100) else { return }

        EnsembleLogger.debug(
            "DownloadQueue aggregate items=\(downloadQueueItemCount) statusPolls=\(downloadQueueStatusPollCount) queueCacheHits=\(downloadQueueCacheHitCount) queueCacheMisses=\(downloadQueueCacheMissCount)"
        )
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
    ) async throws -> (fileURL: URL, suggestedFilename: String?, mimeType: String?) {
        let request = try makeServerRequest(
            url: currentServerURL,
            method: "GET",
            path: "/downloadQueue/\(queueId)/item/\(itemId)/media"
        )
        // The persistent queue owns transient retries, so an unavailable item cannot
        // hold a worker here while other tracks are ready to download.
        let (file, response) = try await ResumableDownload.file(for: request, session: session)
        let suggestedFilename = response.value(forHTTPHeaderField: "Content-Disposition")
            .flatMap { contentDisposition -> String? in
                guard let range = contentDisposition.range(of: "filename=") else { return nil }
                let filename = contentDisposition[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return filename.isEmpty ? nil : String(filename)
            }
        return (file, suggestedFilename, response.value(forHTTPHeaderField: "Content-Type"))
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
